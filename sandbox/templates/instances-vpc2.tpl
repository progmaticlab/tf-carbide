provider_config:
  aws:
    ec2_access_key: "$AWS_ACCESS_KEY_ID"
    ec2_secret_key: "$AWS_SECRET_ACCESS_KEY"
    ssh_public_key: /home/centos/.ssh/id_rsa.pub
    ssh_private_key: /home/centos/.ssh/id_rsa
    ssh_user: centos
    instance_type: $AWS_INSTANCETYPE
    image: $AWS_AMI_IMAGE
    region: $AWS_DEFAULT_REGION
    security_group: $AWS_VPC2_SG_NAME
    vpc_subnet_id: $AWS_VPC2_SUBNET1
    assign_public_ip: yes
    volume_size: 80
    key_pair: $AWS_KEYS
    ntpserver: 0.pool.ntp.org
instances:
  ${AWS_STACK_NAME}-aws-vpc2-control1:
    provider: aws
    instance_type: $AWS_INSTANCETYPE
    roles:
      config_database:
      config:
      control:
      analytics_database:
      analytics:
      webui:
      k8s_master:
      kubemanager:
  ${AWS_STACK_NAME}-aws-vpc2-compute1:
    provider: aws
    instance_type: $AWS_INSTANCETYPE
    roles:
      vrouter:
      k8s_node:
  ${AWS_STACK_NAME}-aws-vpc2-compute2:
    provider: aws
    instance_type: $AWS_INSTANCETYPE
    roles:
      vrouter:
      k8s_node:
global_configuration:
  CONTAINER_REGISTRY: $REGISTRY
  K8S_CLUSTER_NAME: ${AWS_STACK_NAME}-cl2
contrail_configuration:
  CONTRAIL_VERSION: latest
  CLOUD_ORCHESTRATOR: kubernetes
  RABBITMQ_NODE_PORT: 5673
  UPGRADE_KERNEL: false
  CONFIG_NODEMGR__DEFAULTS__minimum_diskGB: "2"
  DATABASE_NODEMGR__DEFAULTS__minimum_diskGB: "2"
  JVM_EXTRA_OPTS: "-Xms1g -Xmx2g"
  KUBERNETES_CLUSTER_NAME: vpc2
  KUBERNETES_POD_SUBNETS: 192.168.0.0/19
  KUBERNETES_SERVICE_SUBNETS: 192.168.32.0/19
  KUBERNETES_IP_FABRIC_SUBNETS: 172.26.1.0/20
  BGP_ASN: 64514