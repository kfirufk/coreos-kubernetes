#!/bin/bash

function install_kubectl {

mkdir -p /opt/bin

curl -o /opt/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/${K8S_VER::-9}/bin/linux/amd64/kubectl
chmod +x /opt/bin/kubectl

}

function init_config {
    local REQUIRED=('ADVERTISE_IP' 'POD_NETWORK' 'ETCD_ENDPOINTS' 'SERVICE_IP_RANGE' 'K8S_SERVICE_IP' 'DNS_SERVICE_IP' 'K8S_VER' 'HYPERKUBE_IMAGE_REPO' 'USE_CALICO')

    if [ -f $ENV_FILE ]; then
        export $(cat $ENV_FILE | xargs)
    fi

    if [ -z $ADVERTISE_IP ]; then
        export ADVERTISE_IP=$(awk -F= '/COREOS_PUBLIC_IPV4/ {print $2}' /etc/environment)
    fi

    for REQ in "${REQUIRED[@]}"; do
        if [ -z "$(eval echo \$$REQ)" ]; then
            echo "Missing required config value: ${REQ}"
            exit 1
        fi
    done
}

function init_flannel {
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
}

function start_addons {
    echo "Waiting for Kubernetes API..."
    until curl --silent "http://127.0.0.1:8080/version"
    do
        sleep 5
    done

    echo
    echo "K8S: DNS addon"
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-de.yaml)" "http://127.0.0.1:8080/apis/extensions/v1beta1/namespaces/kube-system/deployments" > /dev/null
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-svc.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/services" > /dev/null
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-autoscaler-de.yaml)" "http://127.0.0.1:8080/apis/extensions/v1beta1/namespaces/kube-system/deployments" > /dev/null
    echo "K8S: Heapster/InfluxDB/Graphana addon"
    kubectl apply -f /srv/kubernetes/manifests/heapster-influx-graphana-de.yaml,/srv/kubernetes/manifests/heapster-influx-graphana-svc.yaml
    echo "K8S: Kube-Lego addon"
    kubectl apply -f /srv/kubernetes/manifests/kube-lego.yaml
	echo "K8S: NGinx Ingress addon"
    kubectl apply -f /srv/kubernetes/manifests/ingress-nginx.yaml,/srv/kubernetes/manifests/default-backend.yaml
    echo "K8S: Dashboard addon"
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-de.yaml)" "http://127.0.0.1:8080/apis/extensions/v1beta1/namespaces/kube-system/deployments" > /dev/null
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-svc.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/services" > /dev/null
}

function install_ceph {

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
	wget https://github.com/gliderlabs/sigil/releases/download/v${SIGIL}/sigil_${SIGIL}_Linux_x86_64.tgz
	tar -xzvf sigil_${SIGIL}_Linux_x86_64.tgz

	ln -s /opt/sigil /opt/bin/sigil

	export osd_cluster_network=$POD_NETWORK
	export osd_public_network=$POD_NETWORK

	cd /home/core/generator
	./generate_secrets.sh all `./generate_secrets.sh fsid`
	
	kubectl create namespace ceph
	kubectl create secret generic ceph-conf-combined --from-file=ceph.conf --from-file=ceph.client.admin.keyring --from-file=ceph.mon.keyring --namespace=ceph
	kubectl create secret generic ceph-bootstrap-rgw-keyring --from-file=ceph.keyring=ceph.rgw.keyring --namespace=ceph
	kubectl create secret generic ceph-bootstrap-mds-keyring --from-file=ceph.keyring=ceph.mds.keyring --namespace=ceph
	kubectl create secret generic ceph-bootstrap-osd-keyring --from-file=ceph.keyring=ceph.osd.keyring --namespace=ceph
	kubectl create secret generic ceph-client-key --from-file=ceph-client-key --namespace=ceph
	
	kubectl create \
	-f /srv/kubernetes/manifests/ceph-ods.yaml \
	-f /srv/kubernetes/manifests/ceph-mon.yaml \
	-f /srv/kubernetes/manifests/ceph-mds.yaml \
	--namespace=ceph

}	


mkdir -p /opt/ceph
mkdir -p /home/core/data/ceph/osd
mkdir -p /home/core/data/ceph/mon

init_kubectl
init_config
init_flannel
#TODO: parse templates and copy them
systemctl daemon-reload
if [ $CONTAINER_RUNTIME = "rkt" ]; then
        systemctl enable load-rkt-stage1
        systemctl enable rkt-api
fi
systemctl enable flanneld; systemctl start flanneld
systemctl enable kubelet; systemctl start kubelet
if [ $USE_CALICO = "true" ]; then
        start_calico
fi
start_addons
install_ceph
echo "DONE"
