<html>
<body>
  <?php
    $region = getenv('AWS_REG');
    shell_exec("/opt/sandbox/scripts/delete_stack.sh");
    header('Location: https://console.aws.amazon.com/ec2/v2/home?region=' . $region . '#Instances:sort=instanceId');
    exit();
  ?>
</body>
</html>
