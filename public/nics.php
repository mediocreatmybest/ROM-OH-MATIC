<?php
/*
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE.txt
# Website:  http://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
# Support:  xbgmsharp@gmail.com
#------------------------------------------------------------------------
*/

$file_name = 'nics.json';

$cache_path = dirname(__FILE__) . "/cache";
$cache_file = "$cache_path/$file_name";
$cache_life = '3600'; //caching time, in seconds, 1h

$command = "/opt/rom-o-matic/ipxe/src/util/niclist.pl --format json --output \"$cache_file\" 2> /dev/null";

$filemtime = @filemtime($cache_file);  // returns FALSE if file does not exist
if (!$filemtime or (time() - $filemtime >= $cache_life))
{
	exec($command, $output, $result);
}
header('Content-Type: application/json; charset=utf-8');
readfile($cache_file);

?>
