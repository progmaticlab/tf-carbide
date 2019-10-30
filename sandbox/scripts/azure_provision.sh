#!/usr/bin/bash -ex

sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc

sudo sh -c 'echo -e "[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'

sudo yum install azure-cli -y

AZ_USER_ID=$(cat $HOME/azure.json | jq -r '.appId')
AZ_PASSWORD=$(cat $HOME/azure.json | jq -r '.password')
AZ_TENANT=$(cat $HOME/azure.json | jq -r '.tenant')
AZ_RG=${AZ_RG:-TF}

az login --service-principal -u $AZ_USER_ID --password $AZ_PASSWORD --tenant $AZ_TENANT

az network vnet create --resource-group $AZ_RG \
    --name tfVNET \
    --address-prefixes 10.138.0.0/16 \
    --subnet-name tfSUBNET \
    --subnet-prefixes 10.138.0.0/20 \
    --location westus2

az network nsg create --resource-group $AZ_RG \
    --name nsg-tf \
    --location westus2

az network public-ip create --resource-group $AZ_RG \
    --name devstackPubIp \
    --allocation-method Dynamic \
    --location westus2 &

az network public-ip create --resource-group $AZ_RG \
    --name vpnPubIp \
    --allocation-method Dynamic \
    --location westus2 &

wait

az network nic create --resource-group $AZ_RG \
    --name devstackNIC \
    --vnet-name tfVNET \
    --subnet tfSUBNET \
    --private-ip-address 10.138.0.100 \
    --network-security-group nsg-tf \
    --public-ip-address devstackPubIp \
    --location westus2 &

az network nic create --resource-group $AZ_RG \
    --name vpnNIC \
    --vnet-name tfVNET \
    --subnet tfSUBNET \
    --private-ip-address 10.138.0.5 \
    --ip-forwarding \
    --network-security-group nsg-tf \
    --public-ip-address vpnPubIp \
    --location westus2 &

wait

az vm create --resource-group $AZ_RG \
    --name devstack \
    --size Standard_A2m_v2 \
    --os-disk-size-gb 100 \
    --location westus2 \
    --image centos \
    --nics devstackNIC \
    --generate-ssh-keys \
    --output json &

az vm create --resource-group $AZ_RG \
    --name vpn \
    --size Standard_B1ms \
    --location westus2 \
    --image centos \
    --nics vpnNIC \
    --generate-ssh-keys \
    --output json &

az network nsg rule create --nsg-name nsg-tf --resource-group $AZ_RG \
    --name tcp_8143 \
    --priority 100 \
    --protocol Tcp \
    --destination-port-ranges 8143 \
    --source-address-prefixes '*' &

az network nsg rule create --nsg-name nsg-tf --resource-group $AZ_RG \
    --name from_aws \
    --priority 101 \
    --protocol '*' \
    --destination-port-ranges '*' \
    --source-address-prefixes 172.25.1.0/24 &

az network nsg rule create --nsg-name nsg-tf --resource-group $AZ_RG \
    --name tcp_4500 \
    --priority 102 \
    --protocol Tcp \
    --destination-port-ranges 4500 \
    --source-address-prefixes '*'

az network nsg rule create --nsg-name nsg-tf --resource-group $AZ_RG \
    --name udp_4500 \
    --priority 103 \
    --protocol Udp \
    --destination-port-ranges 4500 \
    --source-address-prefixes '*' &

az network nsg rule create --nsg-name nsg-tf --resource-group $AZ_RG \
    --name udp_500 \
    --priority 104 \
    --protocol Udp \
    --destination-port-ranges 500 \
    --source-address-prefixes '*' &

az network nsg rule create --nsg-name nsg-tf --resource-group $AZ_RG \
    --name ssh \
    --priority 105 \
    --protocol Tcp \
    --destination-port-ranges 22 \
    --source-address-prefixes '*' &

az network route-table create --resource-group $AZ_RG \
    --name tfrt \
    --location westus2

az network route-table route create --resource-group $AZ_RG \
    --address-prefix 172.25.1.0/24 \
    --name to_aws \
    --route-table-name tfrt \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address 10.138.0.5

az network vnet subnet update --resource-group $AZ_RG \
    --vnet-name tfVNET \
    --name tfSUBNET \
    --route-table tfrt

wait
