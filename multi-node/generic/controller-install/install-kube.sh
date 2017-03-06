#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="env.sh"
KUBECTL_BIN=/opt/bin/kubectl

source ${DIR}/${ENV_FILE}


function install_kubectl {

echo "installing kubectl..."

mkdir -p /opt/bin
mkdir -p /var/run/calico
curl -o /opt/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/${K8S_VER::-9}/bin/linux/amd64/kubectl
chmod +x ${KUBECTL_BIN}

echo "done installing kubectl"

}

function init_config {

    echo "checking config environment variables..."
    local REQUIRED=('ADVERTISE_IP' 'POD_NETWORK' 'ETCD_ENDPOINTS' 'SERVICE_IP_RANGE' 'K8S_SERVICE_IP' 'DNS_SERVICE_IP' 'K8S_VER' 'HYPERKUBE_IMAGE_REPO' 'USE_CALICO')
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

function start_addons {
    echo "starting addons..."
    echo "Waiting for Kubernetes API..."
    until curl --silent "http://127.0.0.1:8080/version"
    do
        sleep 5
    done

    echo
    echo "K8S: DNS addon"
    ${KUBECTL_BIN} apply -f /srv/kubernetes/manifests/kube-dns-de.yaml -f /srv/kubernetes/manifests/kube-dns-svc.yaml -f /srv/kubernetes/manifests/kube-dns-autoscaler-de.yaml --namespace kube-system

    echo "K8S: Heapster/InfluxDB/Graphana addon"
    ${KUBECTL_BIN} apply -f /srv/kubernetes/manifests/heapster-influx-graphana-de.yaml,/srv/kubernetes/manifests/heapster-influx-graphana-svc.yaml
    echo "K8S: Kube-Lego addon"
    ${KUBECTL_BIN} apply -f /srv/kubernetes/manifests/kube-lego.yaml
	echo "K8S: NGinx Ingress addon"
    ${KUBECTL_BIN} apply -f /srv/kubernetes/manifests/ingress-nginx.yaml -f /srv/kubernetes/manifests/default-backend.yaml
    echo "K8S: Dashboard addon"
    ${KUBECTL_BIN} apply -f /srv/kubernetes/manifests/kube-dashboard-de.yaml -f /srv/kubernetes/manifests/kube-dashboard-svc.yaml --namespace kube-system
   echo "finished starting addons"
}

function install_cni {
	echo "installing cni..."
	wget https://github.com/containernetworking/cni/releases/download/v0.5.0-rc1/cni-amd64-v0.5.0-rc1.tgz -O /tmp/cni.tgz
	tar xvfz /tmp/cni.tgz -C /opt/cni/bin
	rm /tmp/cni.tgz
}

function install_ceph {
        echo "installing ceph..."
	PYTHON=${PYTHON:-"2.7.13.2713"}
	SIGIL=${SIGIL:-"0.4.0"}

	#Make directory
	mkdir -p /opt/bin
	cd /opt


	#Install Python2.7
	wget http://downloads.activestate.com/ActivePython/releases/${PYTHON}/ActivePython-${PYTHON}-linux-x86_64-glibc-2.3.6-401785.tar.gz
	tar -xzvf ActivePython-${PYTHON}-linux-x86_64-glibc-2.3.6-401785.tar.gz

	mv ActivePython-${PYTHON}-linux-x86_64-glibc-2.3.6-401785 apy && cd apy && ./install.sh -I /opt/python/

	ln -s /opt/python/bin/easy_install /opt/bin/easy_install
	ln -s /opt/python/bin/pip /opt/bin/pip
	ln -s /opt/python/bin/python /opt/bin/python
	ln -s /opt/python/bin/virtualenv /opt/bin/virtualenv


	#Install Sigil
	cd /opt
	wget https://github.com/gliderlabs/sigil/releases/download/v${SIGIL}/sigil_${SIGIL}_Linux_x86_64.tgz
	tar -xzvf sigil_${SIGIL}_Linux_x86_64.tgz

	ln -s /opt/sigil /opt/bin/sigil

	export osd_cluster_network=$POD_NETWORK
	export osd_public_network=$POD_NETWORK

	cd /home/core/generator
	./generate_secrets.sh all `./generate_secrets.sh fsid`
	
	${KUBECTL_BIN} create namespace ceph
	${KUBECTL_BIN} create secret generic ceph-conf-combined --from-file=ceph.conf --from-file=ceph.client.admin.keyring --from-file=ceph.mon.keyring --namespace=ceph
	${KUBECTL_BIN} create secret generic ceph-bootstrap-rgw-keyring --from-file=ceph.keyring=ceph.rgw.keyring --namespace=ceph
	${KUBECTL_BIN} create secret generic ceph-bootstrap-mds-keyring --from-file=ceph.keyring=ceph.mds.keyring --namespace=ceph
	${KUBECTL_BIN} create secret generic ceph-bootstrap-osd-keyring --from-file=ceph.keyring=ceph.osd.keyring --namespace=ceph
	${KUBECTL_BIN} create secret generic ceph-client-key --from-file=ceph-client-key --namespace=ceph
	
	${KUBECTL_BIN} create \
	-f /srv/kubernetes/manifests/ceph-osd.yaml \
	-f /srv/kubernetes/manifests/ceph-mon.yaml \
	-f /srv/kubernetes/manifests/ceph-mds.yaml \
	--namespace=ceph
        echo "done installing ceph"
}	

function start_calico {
    echo "starting calico..."
    echo "Waiting for Kubernetes API..."
    # wait for the API
    until curl --silent "http://127.0.0.1:8080/version/"
    do
        sleep 5
    done
    echo "Deploying Calico"
    ${KUBECTL_BIN} apply -f /srv/kubernetes/manifests/calico-config.yaml,/srv/kubernetes/manifests/calico.yaml
    echo "finished starting calico"
}

install_cni
mkdir -p /opt/ceph
mkdir -p /home/core/data/ceph/osd
mkdir -p /home/core/data/ceph/mon

install_kubectl

init_config
init_flannel
systemctl daemon-reload
echo starting docker..
systemctl restart docker


if [ $CONTAINER_RUNTIME = "rkt" ]; then
        echo "enabling load-rkt-stage1"
        systemctl enable load-rkt-stage1
        echo "enabling rkt-api"
        systemctl enable rkt-api
fi
echo "enabling and starting flannel"
systemctl stop flanneld; systemctl enable flanneld; systemctl start flanneld

echo restaring docker service, since it breaks after flanneld restart, donno if its really required
systemctl restart docker

echo "enabling and starting kubelet"
systemctl stop kubelet; systemctl enable kubelet; systemctl start kubelet
if [ $USE_CALICO = "true" ]; then
        start_calico
fi
start_addons
install_ceph
echo "DONE"
