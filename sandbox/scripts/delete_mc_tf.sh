#!/bin/bash -x

GCE_REGION="us-west1"

AWS_VPN=$(aws ec2 describe-vpn-connections --filters "Name=tag-value,Values=${AWS_STACK_NAME}-vpn-connect")
AWS_VPN_ID=$(echo $AWS_VPN | jq -r '.VpnConnections[0].VpnConnectionId')
aws ec2 delete-vpn-connection --vpn-connection-id $AWS_VPN_ID
AWS_CGW=$(aws ec2 describe-customer-gateways --filters "Name=tag-value,Values=${AWS_STACK_NAME}-customer-gw")
AWS_CGW_ID=$(echo $AWS_CGW | jq -r '.CustomerGateways[0].CustomerGatewayId')
AWS_VGW=$(aws ec2 describe-vpn-gateways --filters "Name=tag-value,Values=${AWS_STACK_NAME}-vpn-gw")
AWS_VGW_ID=$(echo $AWS_VGW  | jq -r '.VpnGateways[0].VpnGatewayId')
aws ec2 detach-vpn-gateway --vpc-id $AWS_VPC --vpn-gateway-id $AWS_VGW_ID

i=0
while [ $i -lt 10 ]
do
  ((i++))
  VGW_STATUS=$(aws ec2 describe-vpn-gateways --filters "Name=tag-value,Values=${AWS_STACK_NAME}-vpn-gw" | jq -r '.VpnGateways[0].VpcAttachments[0].State')
  if [[ "$VGW_STATUS" != 'attached' ]]; then
    break
  fi
  sleep 5
done

aws ec2 delete-vpn-gateway --vpn-gateway-id $AWS_VGW_ID
aws ec2 delete-customer-gateway --customer-gateway-id $AWS_CGW_ID

gcloud -q compute instances delete gce-control1 --zone=us-west1-a --delete-disks=all
gcloud -q compute vpn-tunnels delete tf-vpn-connection-to-aws
gcloud -q compute forwarding-rules delete fr-tf-gw-esp --region $GCE_REGION
gcloud -q compute forwarding-rules delete fr-tf-gw-udp500 --region $GCE_REGION
gcloud -q compute forwarding-rules delete fr-tf-gw-udp4500 --region $GCE_REGION
gcloud -q compute firewall-rules delete tf-fw-local
gcloud -q compute firewall-rules delete tf-fw-inet
gcloud -q compute addresses delete tf-node1-int-ip
gcloud -q compute addresses delete tf-gw-ip
gcloud -q compute target-vpn-gateways delete tf-vpn-gw 
gcloud -q compute routes delete to-aws-route
gcloud -q compute networks delete tf-net
