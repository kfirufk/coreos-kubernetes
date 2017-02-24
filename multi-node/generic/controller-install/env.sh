#!/bin/bash
export ETCD_ENDPOINTS=http://127.0.0.1:4001
export ADVERTISE_IP=192.168.1.2
export K8S_VER=v1.6.0-beta.0_coreos.0
export HYPERKUBE_IMAGE_REPO=quay.io/coreos/hyperkube
export POD_NETWORK=10.2.0.0/16
export SERVICE_IP_RANGE=10.3.0.0/24
export K8S_SERVICE_IP=10.3.0.1
export DNS_SERVICE_IP=10.3.0.10
export USE_CALICO=true
export CONTAINER_RUNTIME=rkt
export EMAIL="kfirufk@gmail.com"
export uuid_file="/var/run/kubelet-pod.uuid"
if [ ${USE_CALICO} = "true" ]; then
	export  CALICO_OPTS="--volume cni-bin,kind=host,source=/opt/cni/bin \
        			--mount volume=cni-bin,target=/opt/cni/bin"
else
	export CALICO__OPTS=""
fi
