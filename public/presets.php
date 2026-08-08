<?php
/*
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE
# Website:  https://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
#------------------------------------------------------------------------

Enumerate the build presets in presets/ as a single JSON array.

A preset is a named set of deviations from iPXE's own defaults -- exactly
the shape the advanced wizard already works in, since buildcfgParams()
only ever submits options whose value differs from the parsed default.

Sites can add their own by dropping a .json file into presets/ (a bind
mount over that directory is the intended route for the container), so
every file here is treated as untrusted input: one malformed or
hostile file must not break the dropdown for the rest. Files that fail
to parse or fail shape validation are skipped and logged, rather than
aborting the whole response.

No caching, unlike options.php/nics.php -- there is no expensive command
to amortise here, and a site editing a preset should see the change on
reload rather than up to an hour later.
*/

$presets_dir = dirname(__FILE__) . '/presets';

/* Every value the client will put into the form is validated here rather
 * than trusted on arrival. Options in particular become build.fcgi
 * parameters, whose key format is fixed ("header.h/DEFINE"); anything
 * that does not match is dropped rather than forwarded. */
function validate_preset($data, $filename)
{
	if (!is_array($data)) {
		return 'not a JSON object';
	}
	if (!isset($data['name']) || !is_string($data['name']) || trim($data['name']) === '') {
		return 'missing or empty "name"';
	}
	if (!isset($data['options']) || !is_array($data['options'])) {
		return 'missing "options" object';
	}

	$preset = array(
		'name'    => $data['name'],
		'options' => new stdClass(),
	);

	/* Optional descriptive/provenance fields. Kept as free text -- they
	 * are only ever rendered via textContent on the client. */
	foreach (array('description', 'source', 'notes', 'revision', 'outputformat', 'embed', 'trust_note') as $key) {
		if (isset($data[$key]) && is_string($data[$key])) {
			$preset[$key] = $data[$key];
		}
	}

	/* Checked rather than cast: (bool) "false" is true in PHP, so a file
	 * writing the value as a string would silently turn certificate mode
	 * on. These files are untrusted input and the field is documented as
	 * a boolean, so anything else is reported and ignored. */
	if (isset($data['requires_trust_cert'])) {
		if (is_bool($data['requires_trust_cert'])) {
			$preset['requires_trust_cert'] = $data['requires_trust_cert'];
		} else {
			error_log("presets.php: $filename: \"requires_trust_cert\" must be true or false, ignoring");
		}
	}

	$options = array();
	foreach ($data['options'] as $key => $value) {
		if (!is_string($key) || !preg_match('/^\w+\.h\/\w+$/', $key)) {
			error_log("presets.php: $filename: skipping malformed option key \"$key\"");
			continue;
		}
		if (is_bool($value)) {
			$options[$key] = $value ? 1 : 0;
		} elseif (is_int($value)) {
			$options[$key] = $value;
		} elseif (is_string($value)) {
			$options[$key] = $value;
		} else {
			error_log("presets.php: $filename: skipping option \"$key\" with unsupported value type");
			continue;
		}
	}
	/* Encode as an object even when empty -- an empty PHP array would
	 * otherwise serialise as [] and fail the client's shape check. */
	$preset['options'] = (object) $options;

	return $preset;
}

$presets = array();

if (is_dir($presets_dir)) {
	$files = glob($presets_dir . '/*.json');
	if ($files === false) {
		$files = array();
	}
	sort($files);
	foreach ($files as $file) {
		$raw = @file_get_contents($file);
		if ($raw === false) {
			error_log('presets.php: could not read ' . $file);
			continue;
		}
		$data = json_decode($raw, true);
		if ($data === null) {
			error_log('presets.php: ' . basename($file) . ': invalid JSON (' . json_last_error_msg() . ')');
			continue;
		}
		$result = validate_preset($data, basename($file));
		if (is_string($result)) {
			error_log('presets.php: ' . basename($file) . ': ' . $result);
			continue;
		}
		$presets[] = $result;
	}
}

header('Content-Type: application/json; charset=utf-8');
echo json_encode($presets, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);

?>
