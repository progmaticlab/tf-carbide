#!/bin/bash -e

source /etc/environment

AWS_SECURITY_GROUP=$(curl http://169.254.169.254/latest/meta-data/security-groups)

NODES=($(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep -v ${AWS_STACK_NAME}-master-node | awk '{print $1}'))

K8S_MASTER=$(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[PublicDnsName, InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_control | awk '{print $1}')

K8S_WORKERS=($(aws ec2 describe-instances \
    --filters "Name=tag-value,Values=${AWS_STACK_NAME}*" \
    --filters "Name=instance.group-name,Values=${AWS_SECURITY_GROUP}" \
    --query 'Reservations[*].Instances[*].[PublicDnsName, InstanceId, Tags[?Key==`Name`].Value | [0]]' \
    --output text | grep aws_compute | awk '{print $1}'))

#DELETE test LB chart
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /tmp/sandbox/templates/*.yaml centos@$K8S_MASTER:~
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t $K8S_MASTER << EOF1
 sudo helm delete --purge  my-alb &
exit
EOF1

#DELETE all ALBs tagged by clustername
for alb in $( aws elbv2  describe-load-balancers | grep LoadBalancerArn | cut -f4 -d\" ) ; do
    if ( aws elbv2  describe-tags --resource-arns $alb | grep -q ${AWS_STACK_NAME} )
        then
            aws elbv2  delete-load-balancer --load-balancer-arn $alb
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

#DELETE Target groups
for tg in $( aws elbv2 describe-target-groups  | grep TargetGroupArn | cut -f4 -d\"  ) ; do
      if  ( aws elbv2  describe-tags --resource-arns $tg  | grep -q ${AWS_STACK_NAME}  )
        then
#          aws elbv2 deregister-targets  --target-group-arn $tg  --targets
          aws elbv2 delete-target-group --target-group-arn $tg
        fi
done


#DELETE Keys pair
KPCOUNT=$(aws ec2 describe-key-pairs --output text | grep ${AWS_STACK_NAME}-stack-keys  | wc -l)
if [ $KPCOUNT -gt 0 ]
 then
	aws ec2 delete-key-pair --key-name ${AWS_STACK_NAME}-stack-keys
fi

#CHECK if vpc resources are deleted
for i in {1..36}
do
 alb_check=""
 lb_check=""
 tg_check=""
   for alb in $( aws elbv2  describe-load-balancers | grep LoadBalancerArn | cut -f4 -d\" ) ; do
     if ( aws elbv2  describe-tags --resource-arns $alb | grep -q ${AWS_STACK_NAME} )
         then
             alb_check=false
     fi
 done

 for lb in $(aws elb describe-load-balancers | grep LoadBalancerName | cut -f4 -d\" ) ; do
   if [[ $(aws elb describe-tags --load-balancer-names $lb) =~ $AWS_STACK_NAME ]]
     then
       lb_check=false
   fi
 done

 for lb in $(aws elb describe-load-balancers | grep LoadBalancerName | cut -f4 -d\" ) ; do
   if [[ $(aws elb describe-tags --load-balancer-names $lb) =~ $AWS_STACK_NAME ]]
     then
       tg_check=false
   fi
done
 if [  -z  $alb_check ] && [  -z $lb_check ] && [  -z $tg_check]
 then
 break
 fi
 sleep 5
done

#DELETE MasterNode & Stack
aws cloudformation delete-stack --stack-name ${AWS_STACK_NAME}