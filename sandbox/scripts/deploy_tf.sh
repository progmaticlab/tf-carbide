#!/bin/bash -ex

status_log=/var/log/sandbox/status.log

cd /home/centos

if [[ $BUILD == "stable" ]]
  then
    REGISTRY="carbidesandbox"
    REPOHASH="4bf2fee7bc521e0a59ea5e25f339d185e8ce3977"
  else
    REGISTRY="opencontrailnightly"
fi
AWS_KEYS=${AWS_STACK_NAME}-stack-keys
AWS_AMI_IMAGE=$(curl -s http://169.254.169.254/latest/meta-data/ami-id)
AWS_SECURITY_GROUP=$(curl -s http://169.254.169.254/latest/meta-data/security-groups)
AWS_VPC_SUBNET_ID=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/)/subnet-id)


echo "$(date +"%T %Z"): 2/7 Creating and exporting a key pair ... " >> $status_log
cat /dev/zero | ssh-keygen -q -N ""
aws --region $AWS_DEFAULT_REGION ec2 import-key-pair --key-name $AWS_KEYS --public-key-material file:///home/centos/.ssh/id_rsa.pub


echo "$(date +"%T %Z"): 3/7 Download the repository ... " >> $status_log
git clone https://github.com/Juniper/contrail-ansible-deployer

cd contrail-ansible-deployer
if [[ $BUILD == "stable" ]]
  then
    git checkout $REPOHASH
fi

set +x
config=/home/centos/contrail-ansible-deployer/config/instances.yaml
templ=$(cat /tmp/sandbox/templates/instances.tpl)
content=$(eval "echo \"$templ\"")
echo "$content" > $config
set -x


echo "$(date +"%T %Z"): 4/7 Provision instances ... " >> $status_log
ansible-playbook -i inventory/ playbooks/provision_instances.yml

K8S_MASTER=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
              "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[PublicDnsName, InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_control | awk '{print $1}')
    
K8S_MASTER_PR_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
              "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[PublicDnsName, InstanceId, PrivateIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_control | awk '{print $3}')

K8S_WORKERS=($(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
              "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[PublicDnsName, InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_compute | awk '{print $1}'))
cat ~/.ssh/authorized_keys | ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $K8S_MASTER "cat >> ~/.ssh/authorized_keys"
for i in "${K8S_WORKERS[@]}"
 do
  cat ~/.ssh/authorized_keys | ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $i "cat >> ~/.ssh/authorized_keys"
done

ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t $K8S_MASTER \
  "curl -s $BUCKET_URI/crictl-v1.11.1-linux-amd64.tar.gz -o /tmp/crictl-v1.11.1-linux-amd64.tar.gz && sudo tar zxvf /tmp/crictl-v1.11.1-linux-amd64.tar.gz -C /usr/bin && echo export COMPOSE_HTTP_TIMEOUT=300 | sudo tee /etc/profile.d/compose.sh"
for i in "${K8S_WORKERS[@]}"
 do
  ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t $i \
    "curl -s "$BUCKET_URI"/crictl-v1.11.1-linux-amd64.tar.gz -o /tmp/crictl-v1.11.1-linux-amd64.tar.gz && sudo tar zxvf /tmp/crictl-v1.11.1-linux-amd64.tar.gz -C /usr/bin && echo export COMPOSE_HTTP_TIMEOUT=300 | sudo tee /etc/profile.d/compose.sh"
done


echo "$(date +"%T %Z"): 5/7 Configure instances ... " >> $status_log

sed -i '/ - python-pip/a\    - gcc\n    - python-devel\n    - libffi-devel\n\n- name: upgrade pip\n  pip:\n    name: pip==9.0.3\n    state: forcereinstall' \
playbooks/roles/instance/tasks/install_software_Linux.yml
sed -i 's/    name: docker-compose/    name:\n      - docker-compose==1.24.1\n      - bcrypt==3.1.7/' playbooks/roles/instance/tasks/install_software_Linux.yml
ansible-playbook -i inventory/ playbooks/configure_instances.yml

K8S_MASTER_NODE_PROFILE=$(echo $AWS_MP | awk -F/ '{print $2}')
K8S_WORKER_NODE_PROFILE=$(echo $AWS_WP | awk -F/ '{print $2}')
K8S_MASTER_INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
              "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_control | awk '{print $1}')
K8S_WORKER_INSTANCES_ID=($(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
              "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_compute | awk '{print $1}'))
AWS_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" --query 'SecurityGroups[*].GroupId[]' --output text)
sudo cp /home/centos/.ssh/id_rsa /opt/sandbox/scripts/ && sudo chown apache /opt/sandbox/scripts/id_rsa
sudo chown centos /opt/sandbox/scripts/environment
sudo echo "CONTROLLER=${K8S_MASTER_PR_IP}" > /opt/sandbox/scripts/environment
## start patch contrail-ansible-deployer 
cp /tmp/sandbox/templates/k8s-master-init.yaml.j2 /home/centos/contrail-ansible-deployer/playbooks/roles/k8s/templates
pushd /home/centos/contrail-ansible-deployer/playbooks/roles/k8s/tasks/
awk -v qt="'" '
/- name: enable kubelet service/ {
    print "- name: set cloud provider"
    print "  lineinfile:"
    print "      path: /etc/systemd/system/kubelet.service.d/10-kubeadm.conf"
    print "      regexp: "qt"^Environment=\"KUBELET_KUBECONFIG_ARGS="qt""
    print "      line: "qt"Environment=\"KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf --cloud-provider=aws\""qt""
    print ""
}
{ print }
' configure_k8s_master_node.yml > tmp && mv tmp configure_k8s_master_node.yml

awk '
/^- name: initialize k8s master with listen ip/ {
    print "- name: create k8 master init yaml"
    print "  template:"
    print "    src: k8s-master-init.yaml.j2"
    print "    dest: /tmp/k8s-master-init.yaml"
    print ""
}
{ print }
' configure_k8s_master_node.yml > tmp && mv tmp configure_k8s_master_node.yml

sed -ri 's/\|grep "forever"//g' configure_k8s_master_node.yml

awk '
{gsub(/kubeadm init --token-ttl 0 --kubernetes-version v{{ k8s_version }} --apiserver-advertise-address {{ listen_ip }} --pod-network-cidr {{ kube_pod_subnet }}/,"kubeadm init --ignore-preflight-errors=cri --config /tmp/k8s-master-init.yaml");}1
' configure_k8s_master_node.yml > tmp && mv tmp configure_k8s_master_node.yml

awk '
{gsub(/kubeadm init --token-ttl 0 --kubernetes-version v{{ k8s_version }} --pod-network-cidr {{ kube_pod_subnet }}/,"kubeadm init --ignore-preflight-errors=cri --config /tmp/k8s-master-init.yaml");}1
' configure_k8s_master_node.yml > tmp && mv tmp configure_k8s_master_node.yml

awk -v qt="'" '
/- name: enable kubelet service/ {
    print "- name: set cloud provider"
    print "  lineinfile:"
    print "    path: /etc/systemd/system/kubelet.service.d/10-kubeadm.conf"
    print "    regexp: "qt"^Environment=\"KUBELET_KUBECONFIG_ARGS"qt""
    print "    line: "qt"Environment=\"KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf --cloud-provider=aws\""qt""
    print ""
}
{ print }
' configure_k8s_join_node.yml > tmp && mv tmp configure_k8s_join_node.yml

awk '
{gsub(/kubeadm join --token {{ hostvars\[k8s_master_name\].mastertoken }} --discovery-token-unsafe-skip-ca-verification {{ k8s_master_ip }}:6443/,
    "kubeadm join --ignore-preflight-errors=cri --token {{ hostvars\[k8s_master_name\].mastertoken }} --discovery-token-unsafe-skip-ca-verification {{ k8s_master_ip }}:6443")
}1' configure_k8s_join_node.yml > tmp && mv tmp configure_k8s_join_node.yml
popd

## end patch contrail-ansible-deployer

aws ec2 associate-iam-instance-profile --instance-id $K8S_MASTER_INSTANCE_ID --iam-instance-profile Name="$K8S_MASTER_NODE_PROFILE"
for i in "${K8S_WORKER_INSTANCES_ID[@]}"
 do
  aws ec2 associate-iam-instance-profile --instance-id $i --iam-instance-profile Name="$K8S_WORKER_NODE_PROFILE"
done

aws ec2 create-tags --resources ${K8S_WORKER_INSTANCES_ID[@]} $AWS_SECURITY_GROUP_ID $K8S_MASTER_INSTANCE_ID --tags Key=KubernetesCluster,Value=$AWS_STACK_NAME Key=kubernetes.io/cluster/$AWS_STACK_NAME,Value=owned



echo "$(date +"%T %Z"): 6/7 Install Kubernetes ... " >> $status_log
ansible-playbook -i inventory/ -e orchestrator=kubernetes -e k8s_clustername=$AWS_STACK_NAME playbooks/install_k8s.yml


echo "$(date +"%T %Z"): 7/7 Install Tungsten Fabric ... " >> $status_log
ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_contrail.yml

scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /tmp/sandbox/templates/*.yaml $K8S_MASTER:~
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t $K8S_MASTER << EOF1
 set -ex
 sudo yum install -y wget
 wget -nv https://storage.googleapis.com/kubernetes-helm/helm-v2.9.0-linux-amd64.tar.gz
 tar -xvf helm-v2.9.0-linux-amd64.tar.gz
 sudo mv linux-amd64/helm /usr/bin/
 sudo kubectl create -f rbac-config.yaml
 sudo kubectl create -f aws_esb_storage_class.yaml
 sudo helm init --stable-repo-url https://charts.helm.sh/stable --service-account tiller
 sleep 45
 sudo kubectl get pods --all-namespaces
 sudo helm repo add incubator https://charts.helm.sh/incubator
 sudo helm repo update
 sudo helm install incubator/aws-alb-ingress-controller --set clusterName=$AWS_STACK_NAME --set autoDiscoverAwsRegion=true --set autoDiscoverAwsVpcID=true  --name my-alb --namespace kube-system
exit
EOF1

K8S_DASHBOARD_PRIV_IP=$(ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$K8S_MASTER_PR_IP "sudo kubectl get pods -n kube-system -o wide" | grep kubernetes-dashboard | awk '{print $6}')
K8S_DASHBOARD_PUB=$(ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$K8S_DASHBOARD_PRIV_IP "curl -s http://169.254.169.254/latest/meta-data/public-hostname")
K8S_KUBE_TOKEN_NAME=$(ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$K8S_MASTER_PR_IP "sudo kubectl get secret -n contrail" | grep kubemanager | awk '{print $1}')
K8S_KUBE_TOKEN=$(ssh -i id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@$K8S_MASTER_PR_IP "sudo kubectl describe secret $K8S_KUBE_TOKEN_NAME -n contrail" | grep "token:" | awk '{print $2}' | tr -d '\r')
jq --arg k8s_dashboard $K8S_DASHBOARD_PUB '. + {k8s_dashboard: $k8s_dashboard}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg k8s_token $K8S_KUBE_TOKEN '. + {k8s_token: $k8s_token}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json

echo $K8S_MASTER > /var/www/html/sandbox/dns
echo 1 > /var/www/html/sandbox/stage
echo "$(date +"%T %Z"): Deployment is completed" >> $status_log

exit
