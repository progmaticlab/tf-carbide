#!/usr/bin/bash -ex
source /opt/sandbox/scripts/environment
cd /opt/sandbox/scripts
deployment_name=$1
ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$CONTROLLER "sudo helm delete --purge $deployment_name 2>&1"
