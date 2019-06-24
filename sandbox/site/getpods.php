<html>
<head>
<!-- refresh every 20 seconds -->
<meta http-equiv="refresh" content="20">
</head>
<body>
<?php
    $get_pods = shell_exec('/bin/bash /opt/sandbox/scripts/get_pods.sh');
    echo "<pre>$get_pods</pre>";
?>
</body>
</html>
