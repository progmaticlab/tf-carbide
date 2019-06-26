#!/usr/bin/bash -ex
source /opt/sandbox/scripts/environment
cd /opt/sandbox/scripts
ssh -v -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$CONTROLLER "sudo kubectl get pods --all-namespaces -o wide"
