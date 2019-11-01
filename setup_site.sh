#!/usr/bin/bash -ex

source /etc/environment
status_log=/var/log/sandbox/status.log

setenforce 0

mkdir /opt/sandbox
mkdir /var/log/sandbox
ln -s /var/log/cloud-init.log /var/log/sandbox/cloud-init-output.log
if [ "$DEPLOYMENT_TYPE" == MultiCloud ]; then
    echo "$(date +"%T %Z"): 1/10 The control site is being deployed ... " > $status_log
elif [ "$DEPLOYMENT_TYPE" == MC_AZURE ]; then
    echo "$(date +"%T %Z"): 1/99 The control site is being deployed ... " > $status_log
else
    echo "$(date +"%T %Z"): 1/7 The control site is being deployed ... " > $status_log
fi
touch /var/log/sandbox/ansible-vpc1.log
touch /var/log/sandbox/ansible-vpc2.log
chown -R apache:centos /var/log/sandbox
chmod 775 /var/log/sandbox/
chmod 664 /var/log/sandbox/*.log
touch /var/log/ansible.log
chown centos:apache /var/log/ansible.log
ln -s /var/log/ansible.log /var/log/sandbox/ansible.log
curl -s "$BUCKET_URI"/tungsten_fabric_sandbox.tar.gz -o /tmp/tungsten_fabric_sandbox.tar.gz
tar -xzf /tmp/tungsten_fabric_sandbox.tar.gz -C /tmp
cp -r /tmp/sandbox/site /var/www/html/sandbox
cp -r /tmp/sandbox/scripts /opt/sandbox/scripts
cp -r /tmp/sandbox/ansible-tf /home/centos/ansible-tf
chown -R centos /home/centos/ansible-tf
cp -f /tmp/sandbox/templates/ssl.conf /etc/httpd/conf.d/ssl.conf
ln -s /var/log/sandbox/ /var/www/html/sandbox/debug/logs
chown centos /var/www/html/sandbox/dns /var/www/html/sandbox/stage /var/www/html/sandbox/wp_pass
chown apache:apache /var/www/html/sandbox/upload/ /var/www/html/sandbox/settings.json
usermod -aG apache centos
chmod 664 /var/www/html/sandbox/settings.json
echo "SetEnv AWS_REG ${AWS_DEFAULT_REGION}" >> /var/www/html/sandbox/.htaccess
echo "SetEnv AWS_USERKEY ${AWS_USERKEY}" >> /var/www/html/sandbox/.htaccess
htpasswd -bc /etc/httpd/.htpasswd admin "$1"
service httpd restart
yum -y install epel-release
yum -y install python-pip git unzip jq moreutils gcc python-lxml python-devel openssl-devel
curl -s "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "/tmp/awscli-bundle.zip"
unzip /tmp/awscli-bundle.zip -d/tmp
/tmp/awscli-bundle/install -i /usr/local/aws -b /usr/bin/aws
curl ${BUCKET_URI}/crictl-v1.11.1-linux-amd64.tar.gz -o /tmp/crictl-v1.11.1-linux-amd64.tar.gz
tar zxvf /tmp/crictl-v1.11.1-linux-amd64.tar.gz -C /tmp
echo "apache ALL=(ALL) NOPASSWD:SETENV: /opt/sandbox/scripts/*.sh" > /etc/sudoers.d/777-sandbox

sudo -H -u centos sudo pip install --upgrade pip setuptools
sudo -H -u centos sudo pip install boto boto3 contrail-api-client ipaddr netaddr pystache python-daemon ansible==2.7.12 future
if [ "$DEPLOYMENT_TYPE" == MultiCloud ]; then
    sudo -H -u centos /opt/sandbox/scripts/deploy_mc_on_aws.sh &>> /var/log/sandbox/deployment.log || { echo 99 > /var/www/html/sandbox/stage; curl -s "$BUCKET_URI"/failed-installation.htm; } >> /var/log/sandbox/deployment.log
elif [ "$DEPLOYMENT_TYPE" == MC_AZURE ]; then
    sudo -H -u centos /opt/sandbox/scripts/deploy_mc_on_azure.sh &>> /var/log/sandbox/deployment.log || { echo 99 > /var/www/html/sandbox/stage; curl -s "$BUCKET_URI"/failed-installation.htm; } >> /var/log/sandbox/deployment.log
else
    sudo -H -u centos /opt/sandbox/scripts/deploy_tf.sh &>> /var/log/sandbox/deployment.log || { echo 99 > /var/www/html/sandbox/stage; curl -s "$BUCKET_URI"/failed-installation.htm; } >> /var/log/sandbox/deployment.log
fi
