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

$cache_path = dirname(__FILE__) + "/cache";
$cache_file = "$cache_path/nics.json";
$cache_life = '3600'; //caching time, in seconds, 1h

$filemtime = @filemtime($cache_file);  // returns FALSE if file does not exist
if (!$filemtime or (time() - $filemtime >= $cache_life))
{
	$command = '/opt/ipxe/src/util/niclist.pl --format json --output /var/www/html/cache/nics.json 2> /dev/null';
	exec($command, $output, $result);
}
readfile($cache_file);

?>
