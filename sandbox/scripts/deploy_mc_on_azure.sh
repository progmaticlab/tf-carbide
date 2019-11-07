#!/bin/bash -ex

status_log=/var/log/sandbox/status.log

cd /home/centos

AWS_KEYS=${AWS_STACK_NAME}-stack-keys
AWS_AMI_IMAGE=$(curl -s http://169.254.169.254/latest/meta-data/ami-id)
AWS_SECURITY_GROUP=$(curl -s http://169.254.169.254/latest/meta-data/security-groups)
AWS_VPC_SUBNET_ID=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/)/subnet-id)

echo "$(date +"%T %Z"): 2/8 Creating and exporting a key pair ... " >> $status_log
cat /dev/zero | ssh-keygen -q -N ""
aws --region $AWS_DEFAULT_REGION ec2 import-key-pair --key-name $AWS_KEYS --public-key-material file:///home/centos/.ssh/id_rsa.pub

echo "$(date +"%T %Z"): 3/8 Download the repository ... " >> $status_log
git clone https://github.com/Juniper/contrail-ansible-deployer

cd contrail-ansible-deployer
set +x
config=/home/centos/contrail-ansible-deployer/config/instances.yaml
templ=$(cat /tmp/sandbox/templates/instances.tpl)
content=$(eval "echo \"$templ\"")
echo "$content" > $config
set -x

echo "$(date +"%T %Z"): 4/8 Provision aws and azure instances ... " >> $status_log
ansible-playbook -i inventory/ playbooks/provision_instances.yml &
/opt/sandbox/scripts/azure_provision.sh &
wait

AZ_VPN_PUBIP=$(az network public-ip show -g TF -n vpnPubIp --query "{address: ipAddress}" -o tsv)
AZ_DEV_PUBIP=$(az network public-ip show -g TF -n devstackPubIp --query "{address: ipAddress}" -o tsv)

AWS_CONTROL_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep control | awk '{print $1}')

AWS_COMPUTE1_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute1 | awk '{print $1}')

AWS_COMPUTE2_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute2 | awk '{print $1}')

AWS_MASTER_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep master | awk '{print $1}')

AWS_CONTROL_PRV_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PrivateIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep control | awk '{print $1}')

AWS_COMPUTE1_PRV_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PrivateIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute1 | awk '{print $1}')

AWS_COMPUTE2_PRV_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[PrivateIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep compute2 | awk '{print $1}')

AWS_MASTER_INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep master | awk '{print $1}')

echo "$(date +"%T %Z"): 5/8 Configure instances... " >> $status_log
cd $HOME/ansible-tf
ansible-playbook -i $AWS_CONTROL_PUB_IP,$AWS_COMPUTE1_PUB_IP,$AWS_COMPUTE2_PUB_IP,$AZ_DEV_PUBIP, devstack-node.yml
echo "$(date +"%T %Z"): 6/8 Establish a Site-to-Site VPN Tunnel ... " >> $status_log
cat << EOF > hosts.yml
all:
  children:
    aws:
      hosts:
        aws01:
          ansible_host: $AWS_MASTER_PUB_IP
    gcp:
      hosts:
        gcp01:
          ansible_host: $AZ_VPN_PUBIP
  vars:
    aws_peer: $AWS_MASTER_PUB_IP
    gce_peer: $AZ_VPN_PUBIP
    aws_subnet: 172.25.1.0/24
    gce_subnet: 10.138.0.0/20
EOF
cat $HOME/.ssh/id_rsa.pub >> $HOME/.ssh/authorized_keys

aws ec2 create-route --route-table-id $AWS_RT1 \
                     --destination-cidr-block 10.138.0.0/20 \
                     --instance-id $AWS_MASTER_INSTANCE_ID

aws ec2 modify-instance-attribute --instance-id $AWS_MASTER_INSTANCE_ID --no-source-dest-check
ansible-playbook -i hosts.yml openswan.yml

echo "$(date +"%T %Z"): 7/8 Deploy Tungsten Fabric with Kubernetes ... " >> $status_log

cat << EOF > hosts.yml
all:
  children:
    aws:
      hosts:
        aws1:
          ansible_host: $AWS_CONTROL_PUB_IP
          manifest: aws_manifest.yml
          CONTROLLER_NODES: $AWS_CONTROL_PRV_IP
          AGENT_NODES: "$AWS_COMPUTE1_PRV_IP $AWS_COMPUTE2_PRV_IP"
          CONTRAIL_POD_SUBNET: 10.32.0.0/12
          CONTRAIL_SERVICE_SUBNET: 10.96.0.0/12
    azure:
      hosts:
        azure1:
          ansible_host: $AZ_DEV_PUBIP
          manifest: azure_manifest.yml
          CONTROLLER_NODES: 10.138.0.100
          CONTRAIL_POD_SUBNET: 192.168.0.0/19
          CONTRAIL_SERVICE_SUBNET: 192.168.32.0/19
  vars:
    CONTRAIL_CONTAINER_TAG: master-907
    KUBE_MANIFEST: "/home/centos/tf-devstack/tf-manifest.yml"
    AWS_CONTROL: $AWS_CONTROL_PRV_IP
EOF
ansible-playbook -i hosts.yml devstack.yml

echo "$(date +"%T %Z"): 8/8 Configure the BGP peering  ... " >> $status_log
# add bgp peer
python /opt/sandbox/scripts/provision_control.py --api_server_ip 10.138.0.100  --router_asn 64514
sleep 10
python /opt/sandbox/scripts/add_bgp_router.py tungsten AWS $AWS_CONTROL_PRV_IP 64512 10.138.0.100
python /opt/sandbox/scripts/add_bgp_router.py tungsten AZURE 10.138.0.100 64514 $AWS_CONTROL_PRV_IP

TF_VN_VPC1_SRV_UUID=$(curl -s -X POST -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"fq_name": ["default-domain", "aws-default", "aws-default-service-network"], "type": "virtual-network"}' \
    http://${AWS_CONTROL_PRV_IP}:8082/fqname-to-id | jq -r '.uuid')
TF_VN_VPC1_POD_UUID=$(curl -s -X POST -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"fq_name": ["default-domain", "aws-default", "aws-default-pod-network"], "type": "virtual-network"}' \
    http://${AWS_CONTROL_PRV_IP}:8082/fqname-to-id | jq -r '.uuid')
TF_VN_VPC2_SRV_UUID=$(curl -s -X POST -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"fq_name": ["default-domain", "azure-default", "azure-default-service-network"], "type": "virtual-network"}' \
    http://10.138.0.100:8082/fqname-to-id | jq -r '.uuid')
TF_VN_VPC2_POD_UUID=$(curl -s -X POST -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"fq_name": ["default-domain", "azure-default", "azure-default-pod-network"], "type": "virtual-network"}' \
    http://10.138.0.100:8082/fqname-to-id | jq -r '.uuid')

curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"export_route_target_list": {"route_target": ["target:64512:202"]}}}' \
    http://${AWS_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC1_SRV_UUID}
curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"export_route_target_list": {"route_target": ["target:64512:203"]}}}' \
    http://${AWS_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC1_POD_UUID}
curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"export_route_target_list": {"route_target": ["target:64514:202"]}}}' \
    http://10.138.0.100:8082/virtual-network/${TF_VN_VPC2_SRV_UUID}
curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"export_route_target_list": {"route_target": ["target:64514:203"]}}}' \
    http://10.138.0.100:8082/virtual-network/${TF_VN_VPC2_POD_UUID}

curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64514:202","target:64514:203"]}}}' \
    http://${AWS_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC1_SRV_UUID}
curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64514:202","target:64514:203"]}}}' \
    http://${AWS_CONTROL_PRV_IP}:8082/virtual-network/${TF_VN_VPC1_POD_UUID}
curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64512:202","target:64512:203"]}}}' \
    http://10.138.0.100:8082/virtual-network/${TF_VN_VPC2_SRV_UUID}
curl -X PUT -H "Content-Type: application/json; charset=UTF-8" \
    -d '{"virtual-network": {"import_route_target_list": {"route_target": ["target:64512:202","target:64512:203"]}}}' \
    http://10.138.0.100:8082/virtual-network/${TF_VN_VPC2_POD_UUID}

jq --arg vpc1_control $AWS_CONTROL_PUB_IP '. + {vpc1_control: $vpc1_control}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg vpc2_control $AZ_DEV_PUBIP '. + {vpc2_control: $vpc2_control}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg vpc1_compute1 $AWS_COMPUTE1_PUB_IP '. + {vpc1_compute1: $vpc1_compute1}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json
jq --arg vpc2_compute1 $AWS_COMPUTE2_PUB_IP '. + {vpc2_compute1: $vpc2_compute1}' /var/www/html/sandbox/settings.json | sponge /var/www/html/sandbox/settings.json

echo 3 > /var/www/html/sandbox/stage
echo "$(date +"%T %Z"): Deployment is completed" >> $status_log

if [[ $(echo -n $AWS_USERKEY | md5sum - | awk '{print $1}') == "dd871b217a44efe5ecc1a685fb43d736" ]] || [[ $(echo -n $AWS_USERKEY | md5sum - | awk '{print $1}') == "d2c3e6f7d068b11a7967d6301e4819b2" ]]
  then
    echo "test install" 
  else
    curl -s "$BUCKET_URI"/successful-installation.htm
    curl -H "X-custom: TF-sandbox" http://54.70.115.163/successful-installation.htm
fi
