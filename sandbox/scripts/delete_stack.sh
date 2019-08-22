#!/bin/bash -e

source /etc/environment

AWS_SECURITY_GROUP=$(curl http://169.254.169.254/latest/meta-data/security-groups)

#DELETE tf nodes

NODES=($(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep -v ${AWS_STACK_NAME}-master-node | awk '{print $1}'))
#remove all ALBs tagged by clustername
for alb in $( aws elbv2  describe-load-balancers | grep LoadBalancerArn | cut -f4 -d\" ) ; do
    if ( aws elbv2  describe-tags --resource-arns $alb | grep -q ${AWS_STACK_NAME} )
        then
            vpc=$( aws elbv2  describe-load-balancers --load-balancer-arns $alb | grep VpcId | cut -f4 -d\")
            aws elbv2  delete-load-balancer --load-balancer-arn $alb
            for subnet in $(aws ec2 describe-subnets --filters Name=tag:aws:cloudformation:stack-name,Values=${AWS_STACK_NAME} | grep SubnetId | cut -f4 -d\" ); do
                aws ec2 delete-subnet --subnet-id=$subnet >> /dev/null 2>&1
    done;
    fi
done

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

#DELETE Keys pair
KPCOUNT=$(aws ec2 describe-key-pairs --output text | grep ${AWS_STACK_NAME}-stack-keys  | wc -l)
if [ $KPCOUNT -gt 0 ]
 then
	aws ec2 delete-key-pair --key-name ${AWS_STACK_NAME}-stack-keys
fi

#DELETE MasterNode & Stack
aws cloudformation delete-stack --stack-name ${AWS_STACK_NAME}