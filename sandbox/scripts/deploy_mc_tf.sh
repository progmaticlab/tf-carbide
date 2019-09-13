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

GCE_KEY=${GCE_KEY:-/centos/gce.json}
GCE_REGION=${GCE_REGION:-us-west1}

gcloud -q auth activate-service-account --key-file=gce.json

gcloud config set project $(sudo jq -r '.project_id' $GCE_KEY)

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

aws ec2 enable-vgw-route-propagation --gateway-id $VPN_GW_ID --route-table-id $AWS_RT
