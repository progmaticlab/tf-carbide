#!/bin/bash -ex

export $GCE_KEY=/home/centos/gce.json
KEY_LEN=$(cat $GCE_KEY | wc -w)

[[ $KEY_LEN -ne 0 ]] && MULTICLOUD="yes"
[[ ! -z "$MULTICLOUD" ]] && echo "i run it!"

/opt/sandbox/scripts/deploy_aws_tf.sh >> /var/log/sandbox/aws_deployment.log &
[[ ! -z "$MULTICLOUD" ]] && /opt/sandbox/scripts/deploy_mc_tf.sh >> /var/log/sandbox/gce_deployment.log &

wait

# ToDo healthy

# Provision BGP routers

[[ ! -z "$MULTICLOUD" ]] && python sandbox/scripts/add_bgp_router.py tungsten  AWS $AWS_CONTROL_PRV_IP 64512 $GCE_BGP_IP
[[ ! -z "$MULTICLOUD" ]] && python sandbox/scripts/add_bgp_router.py tungsten  AWS $GCE_BGP_IP 64514 $AWS_CONTROL_PRV_IP

# ToDo TF clusters connectivity test

# Update deploy status to UI
echo $K8S_MASTER > /var/www/html/sandbox/dns
echo 1 > /var/www/html/sandbox/stage
echo "$(date +"%T %Z"): Deployment is completed" >> $status_log

# Deployments counter
if [[ $(echo -n $AWS_USERKEY | md5sum - | awk '{print $1}') == "dd871b217a44efe5ecc1a685fb43d736" ]] || [[ $(echo -n $AWS_USERKEY | md5sum - | awk '{print $1}') == "d2c3e6f7d068b11a7967d6301e4819b2" ]]
  then
    echo "test install" 
  else
    curl -s "$BUCKET_URI"/successful-installation.htm
    curl -H "X-custom: TF-sandbox" http://54.70.115.163/successful-installation.htm
fi
