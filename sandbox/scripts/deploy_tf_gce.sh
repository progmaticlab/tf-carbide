#!/bin/bash -xe

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
cat $SSH_KEY_PATH.pub | sed 's/^/centos: /' > pub_key
gcloud compute instances add-metadata gce-control1 --zone=us-west1-a --metadata-from-file ssh-keys=pub_key

# fix dhcp lease in GCE
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@10.138.0.100 << EOF1
 sudo -s
 set -ex
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
  KUBERNETES_IP_FABRIC_SNAT: true
  KUBERNETES_CLUSTER_NAME: k8s-gce
  KUBERNETES_POD_SUBNETS: 192.168.0.0/19
  KUBERNETES_SERVICE_SUBNETS: 192.168.32.0/19
  KUBERNETES_IP_FABRIC_SUBNETS: 192.168.64.0/19
  BGP_ASN: 64514
EOF

#repo quick fixes
curl https://raw.githubusercontent.com/Juniper/contrail-ansible-deployer/master/playbooks/roles/contrail_deployer/tasks/add_gce_container_hosts.yml > \
  playbooks/roles/contrail_deployer/tasks/add_gce_container_hosts.yml

# set custom ip ranges for K8S
sed -i 's#--pod-network-cidr {{ kube_pod_subnet }}#--pod-network-cidr 192.168.0.0/19 --service-cidr 192.168.32.0/19#g' playbooks/roles/k8s/tasks/configure_k8s_master_node.yml

ansible-playbook -i inventory/ playbooks/configure_instances.yml
ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_k8s.yml
ansible-playbook -i inventory/ -e orchestrator=kubernetes playbooks/install_contrail.yml

#k8s post-fix
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t centos@10.138.0.100 \
  sudo kubectl taint nodes gce-control1 node-role.kubernetes.io/master-
