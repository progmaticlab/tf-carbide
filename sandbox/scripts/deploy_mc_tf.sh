#!/bin/bash -xe

export REPOHASH="4bf2fee7bc521e0a59ea5e25f339d185e8ce3977"
export REGISTRY=${REGISTRY:-carbidesandbox}
cat /dev/zero | ssh-keygen -q -N ""

# Provision GCP instances
[[ -f /etc/yum.repos.d/google-cloud-sdk.repo ]] || sudo tee -a /etc/yum.repos.d/google-cloud-sdk.repo << EOM
[google-cloud-sdk]
name=Google Cloud SDK
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOM

sudo yum install google-cloud-sdk -y

export GCE_KEY=${GCE_KEY:-"/home/centos/gce.json"}
export GCE_REGION=${GCE_REGION:-us-west1}


gcloud -q auth activate-service-account --key-file=$GCE_KEY
gcloud config set project $(sudo jq -r '.project_id' $GCE_KEY)
gcloud services enable compute.googleapis.com
gcloud config set compute/region $GCE_REGION
gcloud -q compute networks create tf-net
gcloud -q compute firewall-rules create tf-net-inet \
    --network tf-net --allow tcp:22,tcp:8143,udp:500,udp:4500,tcp:4500,udp:1194,icmp
gcloud -q compute firewall-rules create tf-net-local \
    --network tf-net --allow all --source-ranges 10.138.0.0/22,172.25.1.0/24

gcloud compute addresses create control1-ip-int \
    --region $GCE_REGION \
    --subnet tf-net \
    --addresses=10.138.0.100 &

gcloud compute addresses create compute1-ip-int \
    --region $GCE_REGION \
    --subnet tf-net \
    --addresses=10.138.0.101 &

gcloud compute addresses create compute2-ip-int \
    --region $GCE_REGION \
    --subnet tf-net \
    --addresses=10.138.0.102 &

wait 

gcloud -q compute instances create gce-control1 \
      --image-family=centos-7 \
      --image-project=centos-cloud \
      --boot-disk-size=100 \
      --zone=us-west1-a \
      --machine-type=n1-standard-4 \
      --can-ip-forward \
      --subnet tf-net \
      --private-network-ip control1-ip-int &

gcloud -q compute instances create gce-compute1 \
      --image-family=centos-7 \
      --image-project=centos-cloud \
      --boot-disk-size=100 \
      --zone=us-west1-a \
      --custom-cpu=2 \
      --custom-memory=13312MB \
      --subnet tf-net \
      --private-network-ip compute1-ip-int &

gcloud -q compute instances create gce-compute2 \
      --image-family=centos-7 \
      --image-project=centos-cloud \
      --boot-disk-size=100 \
      --zone=us-west1-a \
      --custom-cpu=2 \
      --custom-memory=13312MB \
      --subnet tf-net \
      --private-network-ip compute2-ip-int &
wait

sleep 10
cat $HOME/.ssh/id_rsa.pub | sed 's/^/centos: /' > pub_key
cat $HOME/.ssh/authorized_keys | sed 's/^/centos: /' >> pub_key
gcloud compute instances add-metadata gce-control1 --zone=us-west1-a --metadata-from-file ssh-keys=pub_key
gcloud compute instances add-metadata gce-compute1 --zone=us-west1-a --metadata-from-file ssh-keys=pub_key
gcloud compute instances add-metadata gce-compute2 --zone=us-west1-a --metadata-from-file ssh-keys=pub_key

gcloud -q compute routes create to-aws \
    --network=tf-net \
    --destination-range=172.25.1.0/24 \
    --next-hop-instance-zone=us-west1-a \
    --next-hop-instance=gce-control1

GCP_CONTROL_PUB_IP="$(gcloud compute instances describe gce-control1 --zone=us-west1-a --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
GCP_COMPUTE1_PUB_IP="$(gcloud compute instances describe gce-compute1 --zone=us-west1-a --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
GCP_COMPUTE2_PUB_IP="$(gcloud compute instances describe gce-compute2 --zone=us-west1-a --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
GCP_CONTROL_PRV_IP="10.138.0.100"

ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@${GCP_CONTROL_PUB_IP} sudo rm -f /etc/cron.daily/0yum-daily.cron
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@${GCP_COMPUTE1_PUB_IP} sudo rm -f /etc/cron.daily/0yum-daily.cron
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@${GCP_COMPUTE2_PUB_IP} sudo rm -f /etc/cron.daily/0yum-daily.cron


# Provision AWS instances
export REGISTRY="carbidesandbox"
export REPOHASH="4bf2fee7bc521e0a59ea5e25f339d185e8ce3977"
AWS_KEYS=${AWS_STACK_NAME}-stack-keys
AWS_AMI_IMAGE=$(curl -s http://169.254.169.254/latest/meta-data/ami-id)
AWS_SECURITY_GROUP=$(curl -s http://169.254.169.254/latest/meta-data/security-groups)
AWS_VPC_SUBNET_ID=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/)/subnet-id)
aws --region $AWS_DEFAULT_REGION ec2 import-key-pair --key-name $AWS_KEYS --public-key-material file:///home/centos/.ssh/id_rsa.pub

git clone https://github.com/Juniper/contrail-ansible-deployer
cd contrail-ansible-deployer && git checkout $REPOHASH

set +x
config=/home/centos/contrail-ansible-deployer/config/instances.yaml
templ=$(cat /tmp/sandbox/templates/instances.tpl)
content=$(eval "echo \"$templ\"")
echo "$content" > $config
set -x

ansible-playbook -i inventory/ playbooks/provision_instances.yml

"AWS_CONTROL_PUB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[PublicIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_control | awk '{print $1}')

AWS_CONTROL_PRV_IP=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[PrivateIpAddress, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_control | awk '{print $1}')"

AWS_CONTROL_INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_control | awk '{print $1}')

aws ec2 modify-instance-attribute --instance-id $AWS_CONTROL_INSTANCE_ID --no-source-dest-check

aws ec2 create-route --route-table-id $AWS_RT \
                     --destination-cidr-block 10.138.0.0/22 \
                     --instance-id $AWS_CONTROL_INSTANCE_ID

cd $HOME/ansible-openswan
cat << EOF > hosts.yml
all:
  children:
    aws:
      hosts:
        aws01:
          ansible_host: $AWS_CONTROL_PUB_IP
    gcp:
      hosts:
        gcp01:
          ansible_host: $GCP_CONTROL_PUB_IP
  vars:
    aws_peer: $AWS_CONTROL_PUB_IP
    gce_peer: $GCP_CONTROL_PUB_IP
EOF

ansible-playbook -i hosts.yml openswan.yml
cd $HOME

#/opt/sandbox/scripts/deploy_gce_tf.sh >> /var/log/sandbox/gce_deployment.log &
#/opt/sandbox/scripts/deploy_aws_tf.sh >> /var/log/sandbox/aws_deployment.log &

python /opt/sandbox/scripts/add_bgp_router.py tungsten  AWS $AWS_CONTROL_PRV_IP 64512 $GCP_CONTROL_PRV_IP
python /opt/sandbox/scripts/add_bgp_router.py tungsten  GCE $GCP_CONTROL_PRV_IP 64514 $AWS_CONTROL_PRV_IP
