#!/bin/bash -ex

status_log=/var/log/sandbox/status.log

cd $HOME
REGISTRY="carbidesandbox"
REPOHASH="4bf2fee7bc521e0a59ea5e25f339d185e8ce3977"

AWS_KEYS=${AWS_STACK_NAME}-stack-keys
AWS_AMI_IMAGE=$(curl -s http://169.254.169.254/latest/meta-data/ami-id)
AWS_VPC1_SG_NAME=$(aws ec2 describe-security-groups --group-ids $AWS_VPC1_SG --query 'SecurityGroups[*].[GroupName]' --output text)
AWS_VPC2_SG_NAME=$(aws ec2 describe-security-groups --group-ids $AWS_VPC2_SG --query 'SecurityGroups[*].[GroupName]' --output text)

echo "$(date +"%T %Z"): 2/10 Creating and exporting a key pair ... " >> $status_log
cat /dev/zero | ssh-keygen -q -N ""
aws --region $AWS_DEFAULT_REGION ec2 import-key-pair --key-name $AWS_KEYS --public-key-material file:///home/centos/.ssh/id_rsa.pub

echo "$(date +"%T %Z"): 3/10 Download the repository ... " >> $status_log
git clone https://github.com/Juniper/contrail-ansible-deployer $HOME/vpc1-deployer

cd $HOME/vpc1-deployer
git checkout $REPOHASH
cp -ar $HOME/vpc1-deployer $HOME/vpc2-deployer

# set config
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

# repo hot fix 
cp /tmp/sandbox/templates/configure_k8s_* ${HOME}/vpc1-deployer/playbooks/roles/k8s/tasks/
cp /tmp/sandbox/templates/k8s-master-init.yaml.j2 ${HOME}/vpc1-deployer/playbooks/roles/k8s/templates/
cp /tmp/sandbox/templates/configure_k8s_* ${HOME}/vpc2-deployer/playbooks/roles/k8s/tasks/
cp /tmp/sandbox/templates/k8s-master-init.yaml.j2 ${HOME}/vpc2-deployer/playbooks/roles/k8s/templates/

# provision instances
echo "$(date +"%T %Z"): 4/10 Provision instances ... " >> $status_log
cd ${HOME}/vpc1-deployer
sed -i 's#/var/log/ansible.log#var/log/sandbox/ansible-vpc1.log#' ansible.cfg
ansible-playbook -i inventory/ playbooks/provision_instances.yml &
cd ${HOME}/vpc2-deployer
sed -i 's#/var/log/ansible.log#var/log/sandbox/ansible-vpc2.log#' ansible.cfg
ansible-playbook -i inventory/ playbooks/provision_instances.yml &
wait

# change route table
echo "$(date +"%T %Z"): 5/10 Establish a Site-to-Site VPN Tunnel ... " >> $status_log
AWS_VPC1_CONTROL_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws-vpc1-control | awk '{print $1}')

AWS_VPC2_CONTROL_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC2_SG}" \
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

# disable src\dst check for instances
aws ec2 modify-instance-attribute --instance-id $AWS_VPC1_CONTROL_INSTANCE_ID --no-source-dest-check
aws ec2 modify-instance-attribute --instance-id $AWS_VPC2_CONTROL_INSTANCE_ID --no-source-dest-check

# establishe site-to-site vpn 
cd $HOME/ansible-tf
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
# configure instances
echo "$(date +"%T %Z"): 6/10 Configure instances ... " >> $status_log

K8S_MASTER_NODE_PROFILE=$(echo $AWS_MP | awk -F/ '{print $2}')
K8S_WORKER_NODE_PROFILE=$(echo $AWS_WP | awk -F/ '{print $2}')
ALL_MASTER_NODES_ID=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG},${AWS_VPC2_SG}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep control | awk '{print $1}')
ALL_WORKER_NODES_ID=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG},${AWS_VPC2_SG}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute | awk '{print $1}')
VPC1_WORKER_NODES_ID=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute | awk '{print $1}')
VPC2_WORKER_NODES_ID=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC2_SG}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute | awk '{print $1}')

for i in $ALL_MASTER_NODES_ID; do
    aws ec2 associate-iam-instance-profile --instance-id $i --iam-instance-profile Name="$K8S_MASTER_NODE_PROFILE"
done
for i in $ALL_WORKER_NODES_ID; do
    aws ec2 associate-iam-instance-profile --instance-id $i --iam-instance-profile Name="$K8S_WORKER_NODE_PROFILE"
done

aws ec2 create-tags --resources $VPC1_WORKER_NODES_ID $AWS_VPC1_SG $AWS_VPC1_CONTROL_INSTANCE_ID \
    --tags Key=KubernetesCluster,Value=${AWS_STACK_NAME}-vpc1 Key=kubernetes.io/cluster/${AWS_STACK_NAME}-vpc1,Value=owned
aws ec2 create-tags --resources $VPC2_WORKER_NODES_ID $AWS_VPC2_SG $AWS_VPC2_CONTROL_INSTANCE_ID \
    --tags Key=KubernetesCluster,Value=${AWS_STACK_NAME}-vpc2 Key=kubernetes.io/cluster/${AWS_STACK_NAME}-vpc2,Value=owned

ALL_NODES_INV=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_VPC1_SG_NAME},${AWS_VPC2_SG_NAME}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep -v 'master' | awk '{print $1}' | tr '\n' ',')

ansible-playbook -i ${ALL_NODES_INV}, k8s-node.yml

cd ${HOME}/vpc1-deployer
ansible-playbook -i inventory/ playbooks/configure_instances.yml &
cd ${HOME}/vpc2-deployer
ansible-playbook -i inventory/ playbooks/configure_instances.yml &
wait

# k8s deploy
echo "$(date +"%T %Z"): 7/10 Install Kubernetes ... " >> $status_log

cd ${HOME}/vpc1-deployer
ansible-playbook -i inventory/ -e orchestrator=kubernetes -e k8s_clustername=$AWS_STACK_NAME playbooks/install_k8s.yml &
cd ${HOME}/vpc2-deployer
ansible-playbook -i inventory/ -e orchestrator=kubernetes -e k8s_clustername=$AWS_STACK_NAME playbooks/install_k8s.yml &
wait

# tf deploy
echo "$(date +"%T %Z"): 8/10 Install Tungsten Fabric ... " >> $status_log
cd ${HOME}/vpc1-deployer
ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_contrail.yml &
cd ${HOME}/vpc2-deployer
ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_contrail.yml&
wait

# add bgp peer
echo "$(date +"%T %Z"): 9/10 Configure the BGP peering  ... " >> $status_log
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

# import route targets
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
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64512:8000003","target:64512:8000002"]}}}' \
    http://${AWS_VPC2_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC2_SRV_UUID}
curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64512:8000003","target:64512:8000002"]}}}' \
    http://${AWS_VPC2_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC2_POD_UUID}

# install Helm
echo "$(date +"%T %Z"): 10/10 Installing Helm ... " >> $status_log

CONTROL_NODES_INV=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG},${AWS_VPC2_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep -v 'master' | grep control | awk '{print $1}' | tr '\n' ',')

cd $HOME/ansible-tf
ansible-playbook -i $CONTROL_NODES_INV helm.yml \
    -e "aws_region=$AWS_DEFAULT_REGION" \
    -e "aws_vpc1=$AWS_VPC1" \
    -e "aws_vpc2=$AWS_VPC2"

AWS_VPC1_COMPUTE1_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute1 | awk '{print $1}')

AWS_VPC1_COMPUTE2_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute2 | awk '{print $1}')

AWS_VPC2_COMPUTE1_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC2_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute1 | awk '{print $1}')

AWS_VPC2_COMPUTE2_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC2_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute2 | awk '{print $1}')

jq --arg vpc1_control $AWS_VPC1_CONTROL_PUB_IP '. + {vpc1_control: $vpc1_control}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg vpc2_control $AWS_VPC2_CONTROL_PUB_IP '. + {vpc2_control: $vpc2_control}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg vpc1_compute1 $AWS_VPC1_COMPUTE1_PUB_IP '. + {vpc1_compute1: $vpc1_compute1}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg vpc2_compute1 $AWS_VPC2_COMPUTE1_PUB_IP '. + {vpc2_compute1: $vpc2_compute1}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg vpc1_compute2 $AWS_VPC1_COMPUTE2_PUB_IP '. + {vpc1_compute2: $vpc1_compute2}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg vpc2_compute2 $AWS_VPC2_COMPUTE2_PUB_IP '. + {vpc2_compute2: $vpc2_compute2}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json

echo 2 > /var/www/html/sandbox/stage
echo "$(date +"%T %Z"): Deployment is completed" >> $status_log

if [[ $(echo -n $AWS_USERKEY | md5sum - | awk '{print $1}') == "dd871b217a44efe5ecc1a685fb43d736" ]] || [[ $(echo -n $AWS_USERKEY | md5sum - | awk '{print $1}') == "d2c3e6f7d068b11a7967d6301e4819b2" ]]
  then
    echo "test install" 
  else
    curl -s "$BUCKET_URI"/successful-installation.htm
    curl -H "X-custom: TF-sandbox" http://54.70.115.163/successful-installation.htm
fi
