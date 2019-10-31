#!/bin/bash

source /etc/environment
AWS_VPC2_SG=${AWS_VPC2_SG:-$AWS_VPC1_SG}
NODES=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-id,Values=${AWS_VPC1_SG},${AWS_VPC2_SG}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep -v ${AWS_STACK_NAME}-master-node | awk '{print $1}')

for i in "${NODES[@]}"
 do
  ebs_list=($(aws ec2 describe-instances \
     --filters "Name=instance-id,Values=$i" \
     --query 'Reservations[*].Instances[*].BlockDeviceMappings[*].[DeviceName, Ebs.DeleteOnTermination]'\
     --output text | grep False | awk '{print $1}'))
  if [[ ${#ebs_list[*]} -ne 0 ]]
   then 
    for d in "${ebs_list[@]}"
     do
      aws ec2 modify-instance-attribute --instance-id $i --block-device-mappings "[{\"DeviceName\": \"${d}\",\"Ebs\":{\"DeleteOnTermination\":true}}]"
    done
  fi
  unset ebs_list
  aws ec2 terminate-instances --instance-ids $i
done

for lb in $(aws elb describe-load-balancers | grep LoadBalancerName | cut -f4 -d\" ) ; do
  if [[ $(aws elb describe-tags --load-balancer-names $lb) =~ ${AWS_STACK_NAME}-vpc* ]]
    then
      aws elb delete-load-balancer  --load-balancer-name $lb
  fi
done

for alb in $( aws elbv2  describe-load-balancers | grep LoadBalancerArn | cut -f4 -d\" ) ; do
    if ( aws elbv2  describe-tags --resource-arns $alb | grep "kubernetes.io/cluster" | grep -e vpc1 -e vpc2 ); then
        aws elbv2  delete-load-balancer --load-balancer-arn $alb
    fi
done

for tg in $( aws elbv2 describe-target-groups  | grep TargetGroupArn | cut -f4 -d\"  ) ; do
    if ( aws elbv2  describe-tags --resource-arns $tg  | grep -q "kubernetes.io/cluster" | grep -q -e vpc1 -e vpc2 ); then
        aws elbv2 delete-target-group --target-group-arn $tg
    fi
done

KPCOUNT=$(aws ec2 describe-key-pairs --output text | grep ${AWS_STACK_NAME}-stack-keys  | wc -l)
if [ $KPCOUNT -gt 0 ]; then
    aws ec2 delete-key-pair --key-name ${AWS_STACK_NAME}-stack-keys
fi

LB_SG=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${AWS_VPC1},${AWS_VPC2}" \
    --filters "Name=tag:KubernetesCluster,Values=${AWS_STACK_NAME}-vpc1" \
    --filters "Name=group-name,Values=k8s-elb-*" \
    --query 'SecurityGroups[*].[GroupId]' \
    --output text)

HOME=/tmp az login --service-principal -u $AZ_USER_ID --password $AZ_PASSWORD --tenant $AZ_TENANT
HOME=/tmp az group deployment create --no-wait --mode complete --template-uri https://testtf-ek.s3-us-west-1.amazonaws.com/tungsten_fabric_stack_template.yaml --resource-group $AZ_RG

aws cloudformation delete-stack --stack-name ${AWS_STACK_NAME}
