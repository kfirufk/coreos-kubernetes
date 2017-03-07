#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="env.sh"
KUBECTL_BIN=/opt/bin/kubectl

source ${DIR}/${ENV_FILE}

mkdir -p /opt/ceph
mkdir -p /home/core/data/ceph/osd
mkdir -p /home/core/data/ceph/mon

systemctl daemon-reload
if [ $CONTAINER_RUNTIME = "rkt" ]; then
        echo "disabling load-rkt-stage1"
        systemctl disable load-rkt-stage1
	systemctl stop load-rkt-stage1
        echo "disabling rkt-api"
        systemctl disable rkt-api
	systemctl stop rkt-api
fi
echo "disabling flannel"
systemctl stop flanneld; systemctl disable flanneld 

echo "enabling and starting kubelet"
systemctl stop kubelet; systemctl disable kubelet
cho "DONE"
