<?php
$keyname = getenv('AWS_USERKEY');
if (empty($keyname)) {
$keyname = 'userkey';
}
$sandbox_uri = file_get_contents('dns');
$sandbox_uri = preg_replace('/\s+/', '', $sandbox_uri);
?>
<html>
<head>
	<title>Carbide Evaluation System</title>
	<link rel="stylesheet" type="text/css" href="style.css">
	<link rel="shortcut icon" type="image/x-icon" href="tf-favicon.ico">
	<script>
		function resizeIframe(obj) {
		obj.style.height = obj.contentWindow.document.body.scrollHeight + 'px';
		obj.style.width = obj.contentWindow.document.body.scrollWidth + 'px';
		}
	</script>
</head>
<body>
<?php
include 'header.php';
?>
  <h3>List all pods in all namespaces</h3>
 <hr>

<iframe id='dynamic-content' src='getpods.php' frameborder="0" scrolling="no" onload="resizeIframe(this)">
  Not support
 </iframe>

</br>
</br>
<h3>Helm charts</h3>
<hr>

<table>
  <tr>
    <td valign="top">
<form metod="post" enctype="multipart/form-data" method="post">
 <table>
  <tr>
    <td><pre>Install a chart (e.g.: stable/drupal or incubator/logstash):</pre></td>
    <td> <input type="text" name="textline" size="30"> </td>
  </tr>
  <tr>
    <td><pre>Release name (optional):</pre></td> 
    <td> <input type="text" name="deployment" size="30"> </td>
  </tr>
  <tr>
    <td><pre>YAML file that specifies the values (optional):</pre></td>
    <td> <input type="file" name="datafile" size="40"></td>
  </tr>
  <tr>
    <td> <input type="submit" value="Install chart"></td>
    <td> &nbsp; </td>
  </tr>
  <tr>
    <td> &nbsp; </td>
    <td> &nbsp; </td>
  </tr>

  <tr>
    <td><pre> Release name  for deletion (e.g.: my-drupal):</td>
    <td> <input type="text" name="deldeploy" size="30"></td>
  </tr>
  <tr>
    <td> <input type="submit" name="delchart" value="Delete chart"></td>
    <td> &nbsp; </td>
  </tr>
  <tr>
    <td colspan="2"><pre></br></br>*Please delete the installed charts before removing the stack.</pre></td>
  </tr>
 </table>
   </form>
   </td>
   <td valign="top">
   <p style="padding-left: 30px;">For Drupal charts AWS LoadBalancer will be created to allow external access. The FQDN for access can be found in EC2 console or in the output of the command:</p>
   <p style="padding-left: 40px;">Connect to controller:</br>
   <code>ssh -i <?php echo $keyname; ?>.pem centos@<?php echo $sandbox_uri; ?></code></br>
   Get a dns name for access: </br>
   <code>kubectl get svc -o wide | grep my-drupal-drupal | awk '{print $4}'</code></br>
   <p style="padding-left: 30px;">To connect to the services (pod, svc) of the K8S to which access from the outside not configured by default, you can use this path:</p>
   <p style="padding-left: 40px;">Forward a local controller port to a port on the pod: </br>
   <code>kubectl port-forward &lt;pod name|svc name&gt; &lt;local-port&gt;:&lt;pod-port&gt; &amp;</code></br>
   Enable local routing:</br>
   <code>sysctl -w net.ipv4.conf.all.route_localnet=1</code></br>
   Create a rule iptables:</br>
   <code>iptables -t nat -A PREROUTING -p &lt;tcp|udp&gt; -d &lt;172.25.1.xxx&gt; --dport &lt;ext-port&gt; -j DNAT --to-destination 127.0.0.1:&lt;local-port&gt; </code></br>
   If necessary add  inbound rule to the EC2 security group.
   </p>
     </td>
  </tr>
</table>
 </body>
</html>

<?php
  if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    if($_POST['delchart']){
    $name = $_POST['deldeploy'];
    $cmd = shell_exec("/bin/bash /opt/sandbox/scripts/delete_chart.sh '".$name."'");
    echo "<hr>";
    echo "<pre>$cmd</pre>";
 } else {
        $name = $_POST['textline'];
        $dname = $_POST['deployment'];
        if (empty($dname)) {
        $dname = 'free';
             }
        $uploaddir = '/var/www/html/sandbox/upload/';
        $uploadfile = $uploaddir . basename($_FILES['datafile']['name']);
        if (move_uploaded_file($_FILES['datafile']['tmp_name'], $uploadfile)) {
         $uploaded_filename=$_FILES['datafile']['name'];
         $cmd = shell_exec("/bin/bash /opt/sandbox/scripts/install_chart.sh '".$name."' '".$dname."' '".$uploaded_filename."'");
    	 echo "<hr>";
    	 echo "<pre>$cmd</pre>";
    } else {
	 $cmd = shell_exec("/bin/bash /opt/sandbox/scripts/install_chart.sh '".$name."' '".$dname."'");
	 echo "<hr>";
         echo "<pre>$cmd</pre>";
  }
 }
}
?>