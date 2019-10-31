#!/bin/bash -ex

status_log=/var/log/sandbox/status.log

cd /home/centos

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
set +x
config=/home/centos/contrail-ansible-deployer/config/instances.yaml
templ=$(cat /tmp/sandbox/templates/instances.tpl)
content=$(eval "echo \"$templ\"")
echo "$content" > $config
set -x

echo "$(date +"%T %Z"): 4/7 Provision aws and azure instances ... " >> $status_log
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

echo "$(date +"%T %Z"): 5/10 Configure instances... " >> $status_log
cd $HOME/ansible-tf
ansible-playbook -i $AWS_CONTROL_PUB_IP,$AWS_COMPUTE1_PUB_IP,$AWS_COMPUTE2_PUB_IP, devstack-node.yml
echo "$(date +"%T %Z"): 6/10 Establish a Site-to-Site VPN Tunnel ... " >> $status_log
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
EOF
cat $HOME/.ssh/id_rsa.pub >> $HOME/.ssh/authorized_keys

aws ec2 create-route --route-table-id $AWS_RT1 \
                     --destination-cidr-block 10.138.0.0/20 \
                     --instance-id $AWS_MASTER_INSTANCE_ID

aws ec2 modify-instance-attribute --instance-id $AWS_MASTER_INSTANCE_ID --no-source-dest-check
ansible-playbook -i hosts.yml openswan.yml

echo "$(date +"%T %Z"): 7/10 Deploy Tungsten Fabric with Kubernetes ... " >> $status_log

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
