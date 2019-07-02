#!/bin/bash -e

source /etc/environment

AWS_SECURITY_GROUP=$(curl http://169.254.169.254/latest/meta-data/security-groups)

#DELETE tf nodes

NODES=($(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep -v ${AWS_STACK_NAME}-master-node | awk '{print $1}'))

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

aws create-group --name ${AWS_STACK_NAME}-rg \
--resource-query --tags {"aws:cloudformation:stack-name" : ${AWS_STACK_NAME}}
aws resource-groups delete-group --group-name

#DELETE Keys pair
KPCOUNT=$(aws ec2 describe-key-pairs --output text | grep ${AWS_STACK_NAME}-stack-keys  | wc -l)
if [ $KPCOUNT -gt 0 ]
 then
	aws ec2 delete-key-pair --key-name ${AWS_STACK_NAME}-stack-keys
fi

#DELETE MasterNode & Stack
aws cloudformation delete-stack --stack-name ${AWS_STACK_NAME}