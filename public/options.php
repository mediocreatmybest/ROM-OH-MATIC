<?php
/*
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE
# Website:  https://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
# Support:  xbgmsharp@gmail.com
#------------------------------------------------------------------------
*/

$file_name = 'options.json';

$cache_path = dirname(__FILE__) . "/cache";
$cache_file = "$cache_path/$file_name";
$cache_life = '3600'; //caching time, in seconds, 1h

$filemtime = @filemtime($cache_file);  // returns FALSE if file does not exist

if (!$filemtime or (time() - $filemtime >= $cache_life))
{
	// Regenerate via a temporary file and rename into place, rather than
	// redirecting straight onto $cache_file. Writing in place means a
	// parser that fails (or a cache file the web user cannot write)
	// leaves behind a truncated or untouched cache that still looks
	// valid, and the stale copy is then served silently for as long as
	// it exists -- an option list a year out of date is indistinguishable
	// from a fresh one to the caller. The symptom is remote from the
	// cause: presets report their options as "not present in this iPXE
	// revision", because the revision on disk has moved on and the cache
	// has not.
	$tmp_file = @tempnam($cache_path, 'options.');
	$failure = null;

	if ($tmp_file === false) {
		$failure = "could not create a temporary file in $cache_path";
	} else {
		$command = "/opt/rom-o-matic/scripts/parseheaders.py 1> " . escapeshellarg($tmp_file);
		exec($command, $output, $result);

		if ($result !== 0) {
			$failure = "parseheaders.py exited $result";
		} else if (json_decode(@file_get_contents($tmp_file)) === null) {
			// Guards a parser that exits 0 having written nothing, or
			// partial output from a run killed mid-write. Caching that
			// would hide the problem for another $cache_life.
			$failure = 'parseheaders.py produced no usable JSON';
		} else if (!@rename($tmp_file, $cache_file)) {
			$failure = "could not replace $cache_file";
		} else {
			@chmod($cache_file, 0644);
			$tmp_file = null; // renamed away, nothing left to clean up
		}

		if ($tmp_file !== null) {
			@unlink($tmp_file);
		}
	}

	if ($failure !== null) {
		error_log("options.php: could not refresh $file_name ($failure)");

		if (!$filemtime) {
			// No previous cache to fall back on, so there is nothing to
			// serve. Say so rather than returning an empty 200, which the
			// wizard would read as "this iPXE revision has no options".
			http_response_code(500);
			header('Content-Type: application/json; charset=utf-8');
			echo json_encode(array('error' => 'Could not generate the build option list.'));
			exit;
		}
		// Otherwise fall through and serve the previous cache. It is out
		// of date, but a stale option list is more useful than none, and
		// the error log above records why it was not refreshed.
	}
}

header('Content-Type: application/json; charset=utf-8');
readfile($cache_file);

?>
