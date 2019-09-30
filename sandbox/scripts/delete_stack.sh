#!/bin/bash -e

source /etc/environment

AWS_SECURITY_GROUP=$(curl http://169.254.169.254/latest/meta-data/security-groups)

#DELETE tf nodes


#kubectl scale deployment my-alb-aws-alb-ingress-controller  --replicas=0 -n kube-system

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
            alb_release=$(helm list | grep aws-alb-ingress-controller | awk '{print $1}')
            helm delete $alb_release
    fi
done

for lb in $(aws elb describe-load-balancers | grep LoadBalancerName | cut -f4 -d\" ) ; do
  if [[ $(aws elb describe-tags --load-balancer-names $lb) =~ $AWS_STACK_NAME ]]
    then
      aws elb delete-load-balancer  --load-balancer-name $lb
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