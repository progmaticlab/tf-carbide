#!/usr/bin/bash -ex
source /opt/sandbox/scripts/environment
cd /opt/sandbox/scripts
chart_name=$1
short_chart_name=$(echo $chart_name | awk -F/ '{print $2}')

yaml_name=$3
#echo $short_chart_name
#echo "$1 $2 $3"

if [ "$2" = "free" ]
  then
   deployment_name=my-$short_chart_name
  else
   deployment_name=$2
fi

if [ -z "$3" ]
  then
    ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$CONTROLLER \
        "sudo helm repo update; sudo helm install --name $deployment_name ${chart_name} 2>&1"
  else
    scp -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /var/www/html/sandbox/upload/$yaml_name centos@$CONTROLLER:/tmp/ 
    ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$CONTROLLER \
        "sudo helm repo update; sudo helm install --name $deployment_name -f /tmp/$yaml_name ${chart_name} 2>&1"
fi
