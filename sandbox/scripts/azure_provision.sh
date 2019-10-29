date
az network vnet create --resource-group TF \
    --name tfVNET \
    --address-prefixes 10.138.0.0/16 \
    --subnet-name tfSUBNET \
    --subnet-prefixes 10.138.0.0/20 \
    --location westus2

az network nsg create --resource-group TF \
    --name nsg-tf \
    --location westus2

az network public-ip create --resource-group TF \
    --name devstackPubIp \
    --allocation-method Dynamic \
    --location westus2 &

az network public-ip create --resource-group TF \
    --name vpnPubIp \
    --allocation-method Dynamic \
    --location westus2 &

wait

az network nic create --resource-group TF \
    --name devstackNIC \
    --vnet-name tfVNET \
    --subnet tfSUBNET \
    --private-ip-address 10.138.0.100 \
    --network-security-group nsg-tf \
    --public-ip-address devstackPubIp \
    --location westus2 &

az network nic create --resource-group TF \
    --name vpnNIC \
    --vnet-name tfVNET \
    --subnet tfSUBNET \
    --private-ip-address 10.138.0.5 \
    --ip-forwarding \
    --network-security-group nsg-tf \
    --public-ip-address vpnPubIp \
    --location westus2 &

wait

az vm create --resource-group TF \
    --name devstack \
    --size Standard_A2m_v2 \
    --os-disk-size-gb 100 \
    --location westus2 \
    --image centos \
    --nics devstackNIC \
    --generate-ssh-keys \
    --output json &

az vm create --resource-group TF \
    --name vpn \
    --size Standard_B1ms \
    --location westus2 \
    --image centos \
    --nics vpnNIC \
    --generate-ssh-keys \
    --output json &


az network nsg rule create --nsg-name nsg-tf --resource-group TF \
    --name tcp_8143 \
    --priority 100 \
    --protocol Tcp \
    --destination-port-ranges 8143 \
    --source-address-prefixes '*' &

az network nsg rule create --nsg-name nsg-tf --resource-group TF \
    --name from_aws \
    --priority 101 \
    --protocol '*' \
    --destination-port-ranges '*' \
    --source-address-prefixes 172.16.0.0/16 &

az network nsg rule create --nsg-name nsg-tf --resource-group TF \
    --name tcp_4500 \
    --priority 102 \
    --protocol Tcp \
    --destination-port-ranges 4500 \
    --source-address-prefixes '*'

az network nsg rule create --nsg-name nsg-tf --resource-group TF \
    --name udp_4500 \
    --priority 103 \
    --protocol Udp \
    --destination-port-ranges 4500 \
    --source-address-prefixes '*' &

az network nsg rule create --nsg-name nsg-tf --resource-group TF \
    --name udp_500 \
    --priority 104 \
    --protocol Udp \
    --destination-port-ranges 500 \
    --source-address-prefixes '*' &

az network nsg rule create --nsg-name nsg-tf --resource-group TF \
    --name ssh \
    --priority 105 \
    --protocol Tcp \
    --destination-port-ranges 22 \
    --source-address-prefixes '*' &

az network route-table create --resource-group TF \
    --name tfrt \
    --location westus2

az network route-table route create --resource-group TF \
    --address-prefix 172.16.0.0/16 \
    --name to_aws \
    --route-table-name tfrt \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address 10.138.0.5
wait
date


az group deployment create --no-wait --mode complete --template-file ./removeall.json --resource-group TF
az group deployment create  --mode complete --template-file ./removeall.json --resource-group TF