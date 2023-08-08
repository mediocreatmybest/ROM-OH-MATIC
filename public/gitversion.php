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

$command = "git -C /opt/ipxe rev-list --all --max-count=30 --abbrev-commit --abbrev=1";
exec($command, $output, $result);
echo json_encode($output);

?>