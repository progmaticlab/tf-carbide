#!/bin/bash -xe

REPOHASH=${REPOHASH:-4bf2fee7bc521e0a59ea5e25f339d185e8ce3977}
REGISTRY=${REGISTRY:-carbidesandbox}

GCE_KEY_PATH=/home/centos/gce.json
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
GCE_USER_EMAIL=$(jq -r '.client_email' $GCE_KEY_PATH)
GCE_PROJECT_ID=$(jq -r '.project_id'  $GCE_KEY_PATH)


[ -d "$HOME/contrail-ansible-deployer-gce" ] || git clone https://github.com/Juniper/contrail-ansible-deployer.git contrail-ansible-deployer-gce

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
  gce-compute1:
    provider: gce
    roles:
      vrouter:
      k8s_node:
  gce-compute2:
    provider: gce
    roles:
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
  KUBERNETES_IP_FABRIC_SUBNETS: 10.138.0.0/20
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
ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_contrail.yml

#ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@10.138.0.100 \
#  sudo kubectl taint nodes gce-control1 node-role.kubernetes.io/master-
