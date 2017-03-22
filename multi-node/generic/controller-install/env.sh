#!/bin/bash
export MASTER_FQDN=coreos-2.tux-in.com
export MASTER_IP=192.168.1.2
export WORKER_IP=192.168.1.3
export WORKER_FQDN=coreos-3.tux-in.com
export ETCD_ENDPOINTS=http://127.0.0.1:4001
export ADVERTISE_IP=192.168.1.2
export K8S_VER=v1.5.5_coreos.0
export HYPERKUBE_IMAGE_REPO=quay.io/coreos/hyperkube
export POD_NETWORK=10.2.0.0/16
export SERVICE_IP_RANGE=10.3.0.0/24
export K8S_SERVICE_IP=10.3.0.1
export DNS_SERVICE_IP=10.3.0.10
export USE_CALICO=true
export CONTAINER_RUNTIME=rkt
export EMAIL="kfirufk@gmail.com"
export uuid_file="/var/run/kubelet-pod.uuid"

export GCR_VER_KUBERNETES_DASHBOARD_AMD64=v1.6.0
export GCR_URL_KUBERNETES_DASHBOARD_AMD64=gcr.io/google_containers/kubernetes-dashboard-amd64
export GCR_VER_DEFAULTBACKEND=1.3
export GCR_URL_DEFAULTBACKEND=gcr.io/google_containers/defaultbackend
export GCR_VER_HEAPSTER=v1.3.0
export GCR_URL_HEAPSTER=gcr.io/google_containers/heapster
export GCR_VER_ADDON_RESIZER=1.7
export GCR_URL_ADDON_RESIZER=gcr.io/google_containers/addon-resizer
export GCR_VER_HEAPSTER_INFLUXDB=v0.13.0
export GCR_URL_HEAPSTER_INFLUXDB=gcr.io/google_containers/heapster-influxdb
export GCR_VER_HEAPSTER_GRAFANA=v2.6.0-2
export GCR_URL_HEAPSTER_GRAFANA=gcr.io/google_containers/heapster-grafana
export GCR_VER_CLUSTER_PROPORTIONAL_AUTOSCALER_AMD64=1.1.1-r2
export GCR_URL_CLUSTER_PROPORTIONAL_AUTOSCALER_AMD64=gcr.io/google_containers/cluster-proportional-autoscaler-amd64
export GCR_VER_KUBEDNS_AMD64=1.9
export GCR_URL_KUBEDNS_AMD64=gcr.io/google_containers/kubedns-amd64
export GCR_VER_KUBE_DNSMASQ_AMD64=1.4.1
export GCR_URL_KUBE_DNSMASQ_AMD64=gcr.io/google_containers/kube-dnsmasq-amd64
export GCR_VER_DNSMASQ_METRICS_AMD64=1.0.1
export GCR_URL_DNSMASQ_METRICS_AMD64=gcr.io/google_containers/dnsmasq-metrics-amd64
export GCR_VER_EXECHEALTHZ_AMD64=v1.2.0
export GCR_URL_EXECHEALTHZ_AMD64=gcr.io/google_containers/exechealthz-amd64

export QUAY_CALICO_NODE_VER=v1.1.0-2-g60ca42a0
export QUAY_CALICO_CNI_VER=v1.6.1

if [ ${USE_CALICO} = "true" ]; then
	export  CALICO_OPTS="--volume cni-bin,kind=host,source=/opt/cni/bin \
        			--mount volume=cni-bin,target=/opt/cni/bin"
else
	export CALICO__OPTS=""
fi
