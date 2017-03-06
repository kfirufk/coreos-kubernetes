#!/bin/bash

set -o errexit


DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="env.sh"

source ${DIR}/${ENV_FILE}

function init_config {

    echo "checking config environment variables..."
    local REQUIRED=( 'ADVERTISE_IP' 'ETCD_ENDPOINTS' 'CONTROLLER_ENDPOINT' 'DNS_SERVICE_IP' 'K8S_VER' 'HYPERKUBE_IMAGE_REPO' 'USE_CALICO' )

    if [ -z $ADVERTISE_IP ]; then
        export ADVERTISE_IP=$(awk -F= '/COREOS_PUBLIC_IPV4/ {print $2}' /etc/environment)
    fi
    for REQ in "${REQUIRED[@]}"; do
	if [ ! "${!REQ}" ]; then echo "Need to set \$$REQ" >&2; exit 1; fi
    done

    echo "done checking config environment variables..."
}

function init_flannel {
    echo "initializing flannel...."
    echo "Waiting for etcd..."
    while true
    do
        IFS=',' read -ra ES <<< "$ETCD_ENDPOINTS"
        for ETCD in "${ES[@]}"; do
            echo "Trying: $ETCD"
            if [ -n "$(curl --silent "$ETCD/v2/machines")" ]; then
                local ACTIVE_ETCD=$ETCD
                break
            fi
            sleep 1
        done
        if [ -n "$ACTIVE_ETCD" ]; then
            break
        fi
    done
    RES=$(curl --silent -X PUT -d "value={\"Network\":\"$POD_NETWORK\",\"Backend\":{\"Type\":\"vxlan\"}}" "$ACTIVE_ETCD/v2/keys/coreos.com/network/config?prevExist=false")
    if [ -z "$(echo $RES | grep '"action":"create"')" ] && [ -z "$(echo $RES | grep 'Key already exists')" ]; then
        echo "Unexpected error configuring flannel pod network: $RES"
    fi
    echo "done initializing flannel"
}

mkdir -p /var/run/calico
init_config
systemctl daemon-reload

if [ $CONTAINER_RUNTIME = "rkt" ]; then
        echo "enabling load-rkt-stage1"
        systemctl enable load-rkt-stage1
        echo "enabling rkt-api"
        systemctl enable rkt-api
fi
echo "enabling and starting flannel"
systemctl enable flanneld; systemctl start flanneld
echo "enabling and starting kubelet"
systemctl enable kubelet; systemctl start kubelet
echo "DONE"
