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

$file_name = 'nics.json';

$cache_path = dirname(__FILE__) . "/cache";
$cache_file = "$cache_path/$file_name";
$cache_life = '3600'; //caching time, in seconds, 1h

$filemtime = @filemtime($cache_file);  // returns FALSE if file does not exist

if (!$filemtime or (time() - $filemtime >= $cache_life))
{
	// Regenerate via a temporary file and rename into place -- see
	// options.php's identical fix for why: niclist.pl failing (or a
	// cache file the web user cannot write) otherwise left a stale or
	// truncated cache in place, served silently for as long as it
	// exists. Unlike options.php this can't redirect stdout, since
	// niclist.pl writes its own output file via --output; passed a
	// temporary path there instead.
	$tmp_file = @tempnam($cache_path, 'nics.');
	$failure = null;

	if ($tmp_file === false) {
		$failure = "could not create a temporary file in $cache_path";
	} else {
		// niclist.pl scans for drivers relative to the current directory,
		// so it has to be run from within the iPXE source tree -- called
		// from anywhere else it quietly returns an empty list rather than
		// failing, which is how the NIC dropdown ended up empty.
		$command = "cd /opt/rom-o-matic/ipxe/src && ./util/niclist.pl --format json --output " .
			escapeshellarg($tmp_file) . " 2>&1";
		exec($command, $output, $result);

		if ($result !== 0) {
			$failure = "niclist.pl exited $result: " . implode(' ', $output);
		} else if (json_decode(@file_get_contents($tmp_file)) === null) {
			$failure = 'niclist.pl produced no usable JSON';
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
		error_log("nics.php: could not refresh $file_name ($failure)");

		if (!$filemtime) {
			http_response_code(500);
			header('Content-Type: application/json; charset=utf-8');
			echo json_encode(array('error' => 'Could not generate the NIC driver list.'));
			exit;
		}
		// Otherwise fall through and serve the previous cache.
	}
}

header('Content-Type: application/json; charset=utf-8');
readfile($cache_file);

?>
