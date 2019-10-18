<?php
$texstSettings = file_get_contents('settings.json');
$set_array = json_decode($texstSettings, true);

$status_log = 'debug/logs/status.log';
$stage_file = 'stage';
$ansible_log = 'debug/logs/ansible.log';
$deployment_log = 'debug/logs/deployment.log';

$deploying_begin_state = 0;
$completed_state = 1;
$completed_multicloud =2;
$invalid_state = 99;

$keyname = getenv('AWS_USERKEY');
if (empty($keyname)) {
    $keyname = 'userkey';
}
$sandbox_uri = file_get_contents('dns');
$sandbox_uri = preg_replace('/\s+/', '', $sandbox_uri);
$contrailurl = "https://".$sandbox_uri.":8143";

$wp_url = "http://".$sandbox_uri."";
$wp_pass = file_get_contents('wp_pass');

$k8s_dns = $set_array['k8s_dashboard'];
$k8s_url = "https://".$k8s_dns.":8443";
$k8s_token = trim($set_array['k8s_token']);

$vpc1_control = $set_array['vpc1_control'];
$vpc2_control = $set_array['vpc2_control'];
$vpc1_compute1 = $set_array['vpc1_compute1'];
$vpc2_compute1 = $set_array['vpc2_compute1'];
$vpc1_compute2 = $set_array['vpc1_compute2'];
$vpc2_compute2 = $set_array['vpc2_compute2'];


$deploying_state_html = <<<DEPLOYING_STATE
<h3>Deployment is in progress:</h3>
<a><pre>&nbsp;&nbsp;Please wait until the deployment ends.</pre></a>
<hr>
DEPLOYING_STATE;

$completed_state_html = <<<COMPLETED_STATE
<h3>Deployment is completed</h3>
<hr>
<p>Contrail UI: <a href="{$contrailurl}" target="_blank">{$contrailurl}</a></p>
<p style="padding-left: 30px;">User name: <i>admin</i></br>User password: <i>contrail123</i></p>
<p>To use Tungsten Fabric or Kubernetes command line utilities сonnect to the controller using the key specified during the deployment of CloudFormation stack and <b>centos</b> user name.</p>
<p style="padding-left: 30px;">Example:</p>
<p style="padding-left: 40px;"><code>ssh -i $keyname.pem centos@$sandbox_uri</code></br>
<code>sudo kubectl get pods --all-namespaces</code></br>
Note: Connection string there may be differences for your operating system or ssh client.</br>
Use the <i>sudo</i> command to perform tasks with administrator privileges.</p>
<p>You can use UI for Helm chart installation <a href="helm.php" target="_blank">here</a></p>
COMPLETED_STATE;

$completed_multicloud_html = <<<COMPLETED_MC
<h3>Deployment is completed</h3>
<table>
  <tr>
    <td>
      <p><b>VPC1</b></p>
      <p>Tungsten Fabric UI: <a href="https://$vpc1_control:8143" target="_blank">https://$vpc1_control:8143</a></p>
      <p style="padding-left: 30px;">user name: <i>admin</i></br>user password: <i>contrail123</i></p>
      <p>control node: $vpc1_control</br>
      compute1 node: $vpc1_compute1</br>
      compute2 node: $vpc1_compute2</p>
    </td>
    <td>
      <p style="padding-left: 15px;"><b>VPC2</b></p>
      <p style="padding-left: 15px;">Tungsten Fabric UI: <a href="https://$vpc2_control:8143" target="_blank">https://$vpc2_control:8143</a></p>
      <p style="padding-left: 30px;">user name: <i>admin</i></br>user password: <i>contrail123</i></p>
      <p style="padding-left: 15px;">control node: $vpc2_control</br>
      compute1 node: $vpc2_compute1</br>
      compute2 node: $vpc2_compute2</p></td>
  </tr>
</table>
<p>To use Tungsten Fabric or Kubernetes command line utilities сonnect to the controller using the key specified during the deployment of CloudFormation stack and <b>centos</b> user name.</p>
<p style="padding-left: 30px;">Example:</p>
<p style="padding-left: 40px;"><code>ssh -i $keyname centos@$vpc1_control</code></br>
<code>sudo kubectl get pods --all-namespaces</code></br>
Note: Connection string there may be differences for your operating system or ssh client.</br>
Use the <i>sudo</i> command to perform tasks with administrator privileges.</p>
COMPLETED_MC;

$k8s_dashboard_access = <<<K8S_ACCESS
<p>Kubernetes dashboard: <a href="{$k8s_url}" target="_blank">{$k8s_url}</a></p>
<p style="padding-left: 30px;">
- follow this link </br>
- select option "Token" </br>
- copy and paste this string to "Enter token" field </p>
<span style="width:60%; margin-left: 40px; word-wrap:break-word; display:inline-block;font-family: monospace;background-color: #eff0f1;">
$k8s_token</span>
K8S_ACCESS;

$k8s_dashboard_access_manual = <<<K8S_ACCESS_MANUAL
<p>Accessing the Kubernetes dashboard:</a></p>
<p style="padding-left: 30px;"> On the controller:</p>
<p style="padding-left: 40px;"><code>sudo kubectl get pods -n kube-system -o wide | grep dashboard</code></br>
Check the IP column. It tells you the private IP address of the compute node where the dashboard POD is running. You need to find out the associated public IP address (You can use the description of stack instances in the Amazon EC2 console for this task). Once you know it, you can connect to the URL:</br></br>
<code>https://&lt;public-ip&gt;:8443</code></br>
Select the token option. Where can you get the token from? There is one on the controller’s file /root/k8s_dashboard_token.txt , but it only allows to visualize. If you want read-write access do the following:</br></br>
<code>sudo kubectl describe secret `sudo kubectl get secret -n contrail | grep kubemanager | awk '{print $1}'` -n contrail | grep "token:" | awk '{print $2}'</code></br></br>
Take your time to browse the dashboard. During the next exercises, you can choose to do some tasks on the web instead of (or in addition to) the CLI.
K8S_ACCESS_MANUAL;

$references_list = <<<REFERENCES_LIST
<p>References:</p>
<p style="padding-left: 30px;"><a href="https://kubernetes.io/docs/reference/kubectl/overview/#examples-common-operations" target="_blank">kubectl: common operations</a></p>
<p style="padding-left: 30px;"><a href="https://github.com/helm/charts" target="_blank">Helm charts</a></p>
REFERENCES_LIST;

$delete_block_html = <<<DELETE_BLOCK
<hr>
<br>
<form action="delete_stack.php" method="get"
    onSubmit="if(!confirm('Do you really want to delete the sandbox and all its resources?\\nYou will be redirected to the Amazon EC2 Dashboard.')){return false;}">
  <input type="submit" value="Delete Sandbox">
</form>
DELETE_BLOCK;

$wp_block_html = <<<WP_BLOCK
<p>WordPress UI: <a href="{$wp_url}" target="_blank">{$wp_url}</a></p>
<p style="padding-left: 30px;">WordPress <a href="{$wp_url}/wp-admin" target="_blank">Login URL</a>
</br>User name: <i>user</i>
</br>User password: <i>${wp_pass}</i></p>
WP_BLOCK;


$invalid_state_html = <<<INVALID_STATE
<h3>Sandbox is invalid state</h3>
<p>An error occurred while deploying. Please see <a href="debug/logs">logs</a> for details. When this issue is explored, please <a href="/debug">delete</a> the sandbox.</p>
<hr>
<p>Short debugging message:</p>
INVALID_STATE;
?>

<?php
    $stage = trim(file_get_contents ($stage_file));
?>

<html>
<head>
  <title>Carbide Evaluation System</title>
    <style>
       p {
          margin-top: 0.5em;
          margin-bottom: 0.5em;
          }
     </style>
  <link rel="shortcut icon" type="image/x-icon" href="tf-favicon.ico">
  <?php
    if ($stage == $deploying_begin_state) {
      echo '<meta http-equiv="refresh" content="60">';
    }
  ?>
<link rel="stylesheet" type="text/css" href="style.css">
</head>
<body>
<?php include 'header.php'; ?>

<?php
    if ($stage == $deploying_begin_state) {
      echo $deploying_state_html;
      $statusview = file_get_contents($status_log);
      echo "<blockquote>";
      echo nl2br($statusview);
      echo "</blockquote>";      
      }
    if ($stage == $completed_state) {
      if ($set_array['firstrun'] == 'true') {
           $set_array['firstrun'] = 'false';
           $settings = json_encode($set_array);
           file_put_contents ( 'settings.json', $settings);
           $ch = curl_init();
           $ip = $_SERVER['REMOTE_ADDR'];
           curl_setopt($ch, CURLOPT_URL, "http://54.70.115.163/news.gif");
           curl_setopt($ch, CURLOPT_HTTPHEADER, array("X-Forwarded-For: $ip", "User-Agent: Carbide"));
           curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
           $server_output = curl_exec ($ch);
           curl_close($ch);
      }
      echo $completed_state_html;
      if (filter_var($k8s_url, FILTER_VALIDATE_URL) and !empty($k8s_token)) {
           echo $k8s_dashboard_access;
          }else{
           echo $k8s_dashboard_access_manual;
      }
      echo $references_list;
      if (!empty($wp_pass)) {
      echo $wp_block_html;
      }
      echo $delete_block_html;
    }

    if ($stage == $completed_multicloud) {
      if ($set_array['firstrun'] == 'true') {
           $set_array['firstrun'] = 'false';
           $settings = json_encode($set_array);
           file_put_contents ( 'settings.json', $settings);
           $ch = curl_init();
           $ip = $_SERVER['REMOTE_ADDR'];
           curl_setopt($ch, CURLOPT_URL, "http://54.70.115.163/news.gif");
           curl_setopt($ch, CURLOPT_HTTPHEADER, array("X-Forwarded-For: $ip", "User-Agent: Carbide"));
           curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
           $server_output = curl_exec ($ch);
           curl_close($ch);
      }
      echo $completed_multicloud_html;
      echo $references_list;
      if (!empty($wp_pass)) {
      echo $wp_block_html;
      }
      echo $delete_block_html;
    }
    if ($stage == $invalid_state) {
      echo $invalid_state_html;
      $data = array_slice(file ($deployment_log), -20);
      foreach ($data as $line) {
      echo nl2br($line);
       }
    }
?>
</body>
</html>
