import os
import sys
from vnc_api import vnc_api
from netaddr import IPNetwork
from provision_bgp import BgpProvisioner

#python sandbox/scripts/add_bgp_router.py tungsten gcloud2 172.16.1.3 64600 172.25.1.128
provisioner = BgpProvisioner("admin", "c0ntrail123", "admin", sys.argv[5], 8082)
provisioner.add_bgp_router(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
