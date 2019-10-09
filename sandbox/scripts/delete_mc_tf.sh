#!/bin/bash -x

GCE_REGION="us-west1"

gcloud -q compute firewall-rules delete tf-net-inet &
gcloud -q compute firewall-rules delete tf-net-local &
gcloud -q compute routes delete to-aws &
gcloud -q compute instances delete gce-control1 --zone=us-west1-a --delete-disks=all &
gcloud -q compute instances delete gce-compute1 --zone=us-west1-a --delete-disks=all &
gcloud -q compute instances delete gce-compute2 --zone=us-west1-a --delete-disks=all &
wait

gcloud -q compute addresses delete control1-ip-int &
gcloud -q compute addresses delete compute1-ip-int &
gcloud -q compute addresses delete compute2-ip-int &
wait

gcloud -q compute networks delete tf-net
