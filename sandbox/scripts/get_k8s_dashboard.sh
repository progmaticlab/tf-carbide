#!/usr/bin/bash -x
source /opt/sandbox/scripts/environment
cd /opt/sandbox/scripts

K8S_DASHBOARD_PRIV_IP=$(ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$CONTROLLER "sudo kubectl get pods -n kube-system -o wide" | grep kubernetes-dashboard | awk '{print $6}')
K8S_DASHBOARD_PUB=$(ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$K8S_DASHBOARD_PRIV_IP "curl -s http://169.254.169.254/latest/meta-data/public-hostname")
K8S_KUBE_TOKEN_NAME=$(ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$CONTROLLER "sudo kubectl get secret -n contrail" | grep kubemanager | awk '{print $1}')
K8S_KUBE_TOKEN=$(ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$CONTROLLER "sudo kubectl describe secret $K8S_KUBE_TOKEN_NAME -n contrail" | grep "token:" | awk '{print $2}' | tr -d '\r')

jq --arg k8s_dashboard_ip $K8S_DASHBOARD_PUB '. + {k8s_dashboard: $k8s_dashboard}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg k8s_token $K8S_KUBE_TOKEN '. + {k8s_token: $k8s_token}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json