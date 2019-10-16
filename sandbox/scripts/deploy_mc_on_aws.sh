#!/bin/bash -ex

status_log=/var/log/sandbox/status.log

cd /home/centos
BUILD=stable

if [[ $BUILD == "stable" ]]
  then
    REGISTRY="carbidesandbox"
    REPOHASH="4bf2fee7bc521e0a59ea5e25f339d185e8ce3977"
  else
    REGISTRY="opencontrailnightly"
fi
AWS_KEYS=${AWS_STACK_NAME}-stack-keys
AWS_AMI_IMAGE=$(curl -s http://169.254.169.254/latest/meta-data/ami-id)
AWS_VPC1_SG_NAME=$(aws ec2 describe-security-groups --group-ids $AWS_VPC1_SG --query 'SecurityGroups[*].[GroupName]' --output text)
AWS_VPC2_SG_NAME=$(aws ec2 describe-security-groups --group-ids $AWS_VPC2_SG --query 'SecurityGroups[*].[GroupName]' --output text)

echo "$(date +"%T %Z"): 2/7 Creating and exporting a key pair ... " >> $status_log
cat /dev/zero | ssh-keygen -q -N ""
aws --region $AWS_DEFAULT_REGION ec2 import-key-pair --key-name $AWS_KEYS --public-key-material file:///home/centos/.ssh/id_rsa.pub

echo "$(date +"%T %Z"): 3/7 Download the repository ... " >> $status_log
git clone https://github.com/Juniper/contrail-ansible-deployer $HOME/vpc1-deployer

cd $HOME/vpc1-deployer
git checkout $REPOHASH
cp -ar $HOME/vpc1-deployer $HOME/vpc2-deployer

set +x
config=${HOME}/vpc1-deployer/config/instances.yaml
templ=$(cat /tmp/sandbox/templates/instances-vpc1.tpl)
content=$(eval "echo \"$templ\"")
echo "$content" > $config
set -x

set +x
config=${HOME}/vpc2-deployer/config/instances.yaml
templ=$(cat /tmp/sandbox/templates/instances-vpc2.tpl)
content=$(eval "echo \"$templ\"")
echo "$content" > $config
set -x

# hot fix 
sed -i 's#--pod-network-cidr {{ kube_pod_subnet }}#--pod-network-cidr 192.168.0.0/19 --service-cidr 192.168.32.0/19#g' \
  ${HOME}/vpc2-deployer/playbooks/roles/k8s/tasks/configure_k8s_master_node.yml

echo "$(date +"%T %Z"): 4/7 Provision instances ... " >> $status_log
cd ${HOME}/vpc1-deployer
ansible-playbook -i inventory/ playbooks/provision_instances.yml &
cd ${HOME}/vpc2-deployer
ansible-playbook -i inventory/ playbooks/provision_instances.yml &
wait

echo "$(date +"%T %Z"): 4/7 Up site-to-site vpn ... " >> $status_log
AWS_VPC1_CONTROL_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_VPC1_SG_NAME}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws-vpc1-control | awk '{print $1}')

AWS_VPC2_CONTROL_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_VPC2_SG_NAME}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws-vpc2-control | awk '{print $1}')

AWS_VPC1_CONTROL_INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_VPC1_SG_NAME}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws-vpc1-control | awk '{print $1}')

AWS_VPC2_CONTROL_INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_VPC2_SG_NAME}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws-vpc2-control | awk '{print $1}')

aws ec2 create-route --route-table-id $AWS_RT1 \
                     --destination-cidr-block 172.26.1.0/24 \
                     --instance-id $AWS_VPC1_CONTROL_INSTANCE_ID

aws ec2 create-route --route-table-id $AWS_RT2 \
                     --destination-cidr-block 172.25.1.0/24 \
                     --instance-id $AWS_VPC2_CONTROL_INSTANCE_ID

aws ec2 modify-instance-attribute --instance-id $AWS_VPC1_CONTROL_INSTANCE_ID --no-source-dest-check
aws ec2 modify-instance-attribute --instance-id $AWS_VPC2_CONTROL_INSTANCE_ID --no-source-dest-check

cd $HOME/ansible-openswan
cat << EOF > hosts.yml
all:
  children:
    aws:
      hosts:
        aws01:
          ansible_host: $AWS_VPC1_CONTROL_PUB_IP
    gcp:
      hosts:
        gcp01:
          ansible_host: $AWS_VPC2_CONTROL_PUB_IP
  vars:
    aws_peer: $AWS_VPC1_CONTROL_PUB_IP
    gce_peer: $AWS_VPC2_CONTROL_PUB_IP
EOF

ansible-playbook -i hosts.yml openswan.yml

echo "$(date +"%T %Z"): 4/7 Configure instances ... " >> $status_log
cd ${HOME}/vpc1-deployer
ansible-playbook -i inventory/ playbooks/configure_instances.yml &
cd ${HOME}/vpc2-deployer
ansible-playbook -i inventory/ playbooks/configure_instances.yml &
wait

echo "$(date +"%T %Z"): 6/7 Install Kubernetes ... " >> $status_log
cd ${HOME}/vpc1-deployer
ansible-playbook -i inventory/ -e orchestrator=kubernetes -e k8s_clustername=$AWS_STACK_NAME playbooks/install_k8s.yml &
cd ${HOME}/vpc2-deployer
ansible-playbook -i inventory/ -e orchestrator=kubernetes -e k8s_clustername=$AWS_STACK_NAME playbooks/install_k8s.yml &
wait

echo "$(date +"%T %Z"): 7/7 Install Tungsten Fabric ... " >> $status_log
cd ${HOME}/vpc1-deployer
ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_contrail.yml &
cd ${HOME}/vpc2-deployer
ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_contrail.yml&
wait

AWS_VPC1_CONTROL_PRV_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_VPC1_SG_NAME}" \
    --query 'Reservations[*].Instances[*].[PrivateIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws-vpc1-control | awk '{print $1}')

AWS_VPC2_CONTROL_PRV_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_VPC2_SG_NAME}" \
    --query 'Reservations[*].Instances[*].[PrivateIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws-vpc2-control | awk '{print $1}')

python /opt/sandbox/scripts/add_bgp_router.py tungsten  VPC1 $AWS_VPC1_CONTROL_PRV_IP 64512 $AWS_VPC2_CONTROL_PRV_IP
python /opt/sandbox/scripts/add_bgp_router.py tungsten  VPC2 $AWS_VPC2_CONTROL_PRV_IP 64514 $AWS_VPC1_CONTROL_PRV_IP

TF_VN_VPC1_SRV_UUID=$(curl -s -X POST -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"fq_name": ["default-domain", "vpc1-default", "vpc1-default-service-network"], "type": "virtual-network"}' \
    http://${AWS_VPC1_CONTROL_PRV_IP}:8082/fqname-to-id | jq -r '.uuid')
TF_VN_VPC1_POD_UUID=$(curl -s -X POST -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"fq_name": ["default-domain", "vpc1-default", "vpc1-default-pod-network"], "type": "virtual-network"}' \
    http://${AWS_VPC1_CONTROL_PRV_IP}:8082/fqname-to-id | jq -r '.uuid')

TF_VN_VPC2_SRV_UUID=$(curl -s -X POST -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"fq_name": ["default-domain", "vpc2-default", "vpc2-default-service-network"], "type": "virtual-network"}' \
    http://${AWS_VPC2_CONTROL_PRV_IP}:8082/fqname-to-id | jq -r '.uuid')
TF_VN_VPC2_POD_UUID=$(curl -s -X POST -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"fq_name": ["default-domain", "vpc2-default", "vpc2-default-pod-network"], "type": "virtual-network"}' \
    http://${AWS_VPC2_CONTROL_PRV_IP}:8082/fqname-to-id | jq -r '.uuid')

curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64514:8000003","target:64514:8000002"]}}}' \
    http://${AWS_VPC1_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC1_SRV_UUID}
curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64514:8000003","target:64514:8000002"]}}}' \
    http://${AWS_VPC1_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC1_POD_UUID}

curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64514:8000003","target:64514:8000002"]}}}' \
    http://${AWS_VPC2_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC2_SRV_UUID}
curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64514:8000003","target:64514:8000002"]}}}' \
    http://${AWS_VPC2_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC2_POD_UUID}
