#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="env.sh"
KUBECTL_BIN=/opt/bin/kubectl

source ${DIR}/${ENV_FILE}

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

echo "disabling and stopping kubelet"
systemctl stop kubelet; systemctl disable kubelet
echo "stopping rkt pods"
timeout 30 rkt list --full 2>/dev/null | awk '{print $1}' | xargs rkt stop
timeout 30 rkt list --full 2>/dev/null | awk '{print $1}' | xargs rkt rm

echo "DONE"
