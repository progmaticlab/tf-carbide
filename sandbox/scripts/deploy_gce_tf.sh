#!/bin/bash -xe

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

sudo yum install google-cloud-sdk python-demjson -y
sudo pip install yq

GCE_KEY=${GCE_KEY:-"/home/centos/gce.json"}
GCE_REGION=${GCE_REGION:-us-west1}

gcloud -q auth activate-service-account --key-file=$GCE_KEY

gcloud config set project $(sudo jq -r '.project_id' $GCE_KEY)

gcloud services enable compute.googleapis.com

gcloud config set compute/region $GCE_REGION

gcloud -q compute networks create tf-net

gcloud -q compute target-vpn-gateways create tf-vpn-gw --network tf-net

gcloud -q compute addresses create tf-gw-ip --region $GCE_REGION

TF_VPN_IP_GW=$(gcloud -q compute addresses describe tf-gw-ip --format='flattened(address)' --region $GCE_REGION | awk '{print $NF}')

gcloud -q compute firewall-rules create tf-fw-local \
    --network tf-net --allow all --source-ranges 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16

gcloud -q compute firewall-rules create tf-fw-inet \
    --network tf-net --allow tcp:22,tcp:3389,tcp:8143,icmp

gcloud -q compute forwarding-rules create fr-tf-gw-esp \
    --ip-protocol ESP \
    --address $TF_VPN_IP_GW \
    --target-vpn-gateway tf-vpn-gw \
    --region $GCE_REGION

gcloud -q compute forwarding-rules create fr-tf-gw-udp500 \
    --ip-protocol UDP \
    --ports 500 \
    --address $TF_VPN_IP_GW \
    --target-vpn-gateway tf-vpn-gw \
    --region $GCE_REGION

gcloud -q compute forwarding-rules create fr-tf-gw-udp4500 \
    --ip-protocol UDP \
    --ports 4500 \
    --address $TF_VPN_IP_GW \
    --target-vpn-gateway tf-vpn-gw \
    --region $GCE_REGION

VPN_GW_ID=$(aws ec2 create-vpn-gateway --type ipsec.1 | jq -r '.VpnGateway.VpnGatewayId')
aws ec2 create-tags --resources $VPN_GW_ID --tags Key=Name,Value=${AWS_STACK_NAME}-vpn-gw
aws ec2 attach-vpn-gateway --vpn-gateway-id $VPN_GW_ID --vpc-id $AWS_VPC

i=0
while [ $i -lt 10 ]
do
  ((i++))
  VGW_STATUS=$(aws ec2 describe-vpn-gateways --filters "Name=tag-value,Values=${AWS_STACK_NAME}-vpn-gw" | jq -r '.VpnGateways[].VpcAttachments[].State')
  if [[ "$VGW_STATUS" == 'attached' ]]; then
    break
  fi
  sleep 5
done

CUS_GW_ID=$(aws ec2 create-customer-gateway --type ipsec.1 --public-ip $TF_VPN_IP_GW --bgp-asn 65000 | jq -r '.CustomerGateway.CustomerGatewayId')
aws ec2 create-tags --resources $CUS_GW_ID --tags Key=Name,Value=${AWS_STACK_NAME}-customer-gw

VPN_CONF=$(aws ec2 create-vpn-connection --type ipsec.1 --customer-gateway-id $CUS_GW_ID --vpn-gateway-id $VPN_GW_ID --options "{\"StaticRoutesOnly\":true}")
VPN_CONF_XML=$(echo $VPN_CONF | jq -r '.VpnConnection.CustomerGatewayConfiguration')
AWS_VPN_ID=$(echo $VPN_CONF | jq -r '.VpnConnection.VpnConnectionId')
AWS_VPN_IP=$(echo $VPN_CONF_XML | xq '.' | jq -r '.vpn_connection.ipsec_tunnel[0].vpn_gateway.tunnel_outside_address.ip_address')
AWS_VPN_KEY=$(echo $VPN_CONF_XML | xq '.' | jq -r '.vpn_connection.ipsec_tunnel[0].ike.pre_shared_key')
aws ec2 create-tags --resources $AWS_VPN_ID --tags Key=Name,Value=${AWS_STACK_NAME}-vpn-connect
aws ec2 create-vpn-connection-route --vpn-connection-id $AWS_VPN_ID --destination-cidr-block 10.138.0.0/20

gcloud -q compute vpn-tunnels create tf-vpn-connection-to-aws  \
    --peer-address $AWS_VPN_IP \
    --ike-version 1 \
    --shared-secret $AWS_VPN_KEY \
    --local-traffic-selector=0.0.0.0/0 \
    --remote-traffic-selector=0.0.0.0/0 \
    --target-vpn-gateway tf-vpn-gw

gcloud -q compute routes create to-aws-route \
    --destination-range 172.25.0.0/16 \
    --next-hop-vpn-tunnel tf-vpn-connection-to-aws \
    --network tf-net \
    --next-hop-vpn-tunnel-region $GCE_REGION

gcloud -q compute routes create to-aws-service-net \
    --destination-range 10.96.0.0/12 \
    --next-hop-vpn-tunnel tf-vpn-connection-to-aws \
    --network tf-net \
    --next-hop-vpn-tunnel-region $GCE_REGION

gcloud -q compute routes create to-aws-pod-net \
    --destination-range 10.32.0.0/12 \
    --next-hop-vpn-tunnel tf-vpn-connection-to-aws \
    --network tf-net \
    --next-hop-vpn-tunnel-region $GCE_REGION

gcloud -q compute routes create to-aws-fabric-net \
    --destination-range 10.64.0.0/12 \
    --next-hop-vpn-tunnel tf-vpn-connection-to-aws \
    --network tf-net \
    --next-hop-vpn-tunnel-region $GCE_REGION


aws ec2 enable-vgw-route-propagation --gateway-id $VPN_GW_ID --route-table-id $AWS_RT

sudo pip install apache-libcloud chardet==2.3.0
[ -d "$HOME/contrail-ansible-deployer-gce" ] || git clone https://github.com/Juniper/contrail-ansible-deployer.git contrail-ansible-deployer-gce
REPOHASH="4bf2fee7bc521e0a59ea5e25f339d185e8ce3977"
GCE_KEY_PATH="$HOME/gce.json"
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
GCE_USER_EMAIL=$(jq -r '.client_email' $GCE_KEY_PATH)
GCE_PROJECT_ID=$(jq -r '.project_id'  $GCE_KEY_PATH)
REGISTRY=${REGISTRY:-carbidesandbox}

gcloud -q compute addresses create tf-node1-int-ip \
    --region us-west1 --subnet tf-net --addresses 10.138.0.100
gcloud -q compute instances create gce-control1 \
      --image-family=centos-7 \
      --image-project=centos-cloud \
      --boot-disk-size=100 \
      --machine-type=n1-standard-8 \
      --network=tf-net \
      --zone=us-west1-a \
      --private-network-ip tf-node1-int-ip
sleep 10
cat $HOME/.ssh/authorized_keys | sed 's/^/centos: /' > pub_key
gcloud compute instances add-metadata gce-control1 --zone=us-west1-a --metadata-from-file ssh-keys=pub_key

# fix dhcp lease in GCE
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@10.138.0.100 << EOF1
sudo -s
rm -f /etc/cron.daily/0yum-daily.cron
sed -i 's/dhcp/none/g'  /etc/sysconfig/network-scripts/ifcfg-eth0
echo "IPADDR=10.138.0.100" >> /etc/sysconfig/network-scripts/ifcfg-eth0
echo "NETMASK=255.255.240.0" >> /etc/sysconfig/network-scripts/ifcfg-eth0
echo "GATEWAY=10.138.0.1" >> /etc/sysconfig/network-scripts/ifcfg-eth0
echo "DNS1=169.254.169.254" >> /etc/sysconfig/network-scripts/ifcfg-eth0
systemctl restart network
exit
exit
EOF1

cd $HOME/contrail-ansible-deployer-gce
git reset --hard && git checkout $REPOHASH
cat << EOF > config/instances.yaml
provider_config:
  gce:
    service_account_email: $GCE_USER_EMAIL
    credentials_file: $GCE_KEY_PATH
    project_id: $GCE_PROJECT_ID
    ssh_user: centos
    ssh_private_key: $SSH_KEY_PATH
    machine_type: n1-standard-8
    image: centos-7
    network: tf-net
    subnetwork: tf-net
    zone: us-west1-a
    disk_size: 50
    ntpserver: 0.pool.ntp.org
instances:
  gce-control1:
    provider: gce
    roles:
      config_database:
      config:
      control:
      analytics_database:
      analytics:
      webui:
      k8s_master:
      kubemanager:
      vrouter:
      k8s_node:
global_configuration:
  CONTAINER_REGISTRY: $REGISTRY
contrail_configuration:
  CONTRAIL_VERSION: latest
  CLOUD_ORCHESTRATOR: kubernetes
  RABBITMQ_NODE_PORT: 5673
  UPGRADE_KERNEL: false
  CONFIG_NODEMGR__DEFAULTS__minimum_diskGB: "6"
  DATABASE_NODEMGR__DEFAULTS__minimum_diskGB: "6"
  JVM_EXTRA_OPTS: "-Xms1g -Xmx2g"
  KUBERNETES_CLUSTER_NAME: k8s-gce
  KUBERNETES_POD_SUBNETS: 192.168.0.0/19
  KUBERNETES_SERVICE_SUBNETS: 192.168.32.0/19
  KUBERNETES_IP_FABRIC_SUBNETS: 192.138.64.0/19
  BGP_ASN: 64514
EOF

#repo quick fixes
curl https://raw.githubusercontent.com/Juniper/contrail-ansible-deployer/master/playbooks/roles/contrail_deployer/tasks/add_gce_container_hosts.yml > \
  playbooks/roles/contrail_deployer/tasks/add_gce_container_hosts.yml

# set custom ip ranges for K8S
sed -i 's#--pod-network-cidr {{ kube_pod_subnet }}#--pod-network-cidr 192.168.0.0/19 --service-cidr 192.168.32.0/19#g' \
  playbooks/roles/k8s/tasks/configure_k8s_master_node.yml

ansible-playbook -i inventory/ playbooks/configure_instances.yml
ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_k8s.yml

ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@10.138.0.100 \
  sudo kubectl taint nodes gce-control1 node-role.kubernetes.io/master-

ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_contrail.yml

#k8s post-fix
