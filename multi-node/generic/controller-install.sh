#!/bin/bash
set -e

# List of etcd servers (http://ip:port), comma separated
export ETCD_ENDPOINTS=

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
export K8S_VER=v1.5.2_coreos.0

# Hyperkube image repository to use.
export HYPERKUBE_IMAGE_REPO=quay.io/coreos/hyperkube

# The CIDR network to use for pod IPs.
# Each pod launched in the cluster will be assigned an IP out of this range.
# Each node will be configured such that these IPs will be routable using the flannel overlay network.
export POD_NETWORK=10.2.0.0/16

# The CIDR network to use for service cluster IPs.
# Each service will be assigned a cluster IP out of this range.
# This must not overlap with any IP ranges assigned to the POD_NETWORK, or other existing network infrastructure.
# Routing to these IPs is handled by a proxy service local to each node, and are not required to be routable between nodes.
export SERVICE_IP_RANGE=10.3.0.0/24

# The IP address of the Kubernetes API Service
# If the SERVICE_IP_RANGE is changed above, this must be set to the first IP in that range.
export K8S_SERVICE_IP=10.3.0.1

# The IP address of the cluster DNS service.
# This IP must be in the range of the SERVICE_IP_RANGE and cannot be the first IP in the range.
# This same IP must be configured on all worker nodes to enable DNS service discovery.
export DNS_SERVICE_IP=10.3.0.10

# Whether to use Calico for Kubernetes network policy.
export USE_CALICO=false

# Determines the container runtime for kubernetes to use. Accepts 'docker' or 'rkt'.
export CONTAINER_RUNTIME=docker

# System administrator email address
export EMAIL=

# The above settings can optionally be overridden using an environment file:
ENV_FILE=/run/coreos-kubernetes/options.env

# -------------

mkdir -p /opt/ceph
mkdir -p /home/core/data/ceph/osd
mkdir -p /home/core/data/ceph/mon

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

function init_templates {
    local TEMPLATE=/etc/systemd/system/kubelet.service
    local uuid_file="/var/run/kubelet-pod.uuid"
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
    # To run a self hosted Calico install it needs to be able to write to the CNI dir
    if [ ${USE_CALICO} = "true" ]; then
        local CALICO_OPTS="--volume cni-bin,kind=host,source=/opt/cni/bin \
        --mount volume=cni-bin,target=/opt/cni/bin"
		mkdir -p /lib/modules
		mkdir -p /var/run/calico
		mkdir -p /opt/cni/bin
		mkdir -p /etc/kubernetes/cni/net.d
        echo "RKT Configured for Calico Binaries"
    else
        local CALICO_OPTS=""
    fi
    cat << EOF > $TEMPLATE
[Service]
Environment=KUBELET_VERSION=${K8S_VER}
Environment=KUBELET_ACI=${HYPERKUBE_IMAGE_REPO}
Environment="RKT_OPTS=--uuid-file-save=${uuid_file} \
  --volume dns,kind=host,source=/run/systemd/resolve/resolv.conf \
  --mount volume=dns,target=/etc/resolv.conf \
  --volume rkt,kind=host,source=/opt/bin/host-rkt \
  --mount volume=rkt,target=/usr/bin/rkt \
  --volume var-lib-rkt,kind=host,source=/var/lib/rkt \
  --mount volume=var-lib-rkt,target=/var/lib/rkt \
  --volume stage,kind=host,source=/tmp \
  --mount volume=stage,target=/tmp \
  --volume var-log,kind=host,source=/var/log \
  --mount volume=var-log,target=/var/log \
  ${CALICO_OPTS}"
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests
ExecStartPre=/usr/bin/mkdir -p /opt/cni/bin
ExecStartPre=/usr/bin/mkdir -p /var/log/containers
ExecStartPre=-/usr/bin/rkt rm --uuid-file=${uuid_file}
ExecStart=/usr/lib/coreos/kubelet-wrapper \
  --api-servers=http://127.0.0.1:8080 \
  --register-schedulable=true \
  --cni-conf-dir=/etc/kubernetes/cni/net.d \
  --network-plugin=cni \
  --container-runtime=${CONTAINER_RUNTIME} \
  --rkt-path=/usr/bin/rkt \
  --rkt-stage1-image=coreos.com/rkt/stage1-coreos \
  --allow-privileged=true \
  --pod-manifest-path=/etc/kubernetes/manifests \
  --hostname-override=${ADVERTISE_IP} \
  --cluster_dns=${DNS_SERVICE_IP} \
  --cluster_domain=cluster.local
ExecStop=-/usr/bin/rkt stop --uuid-file=${uuid_file}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    fi

    local TEMPLATE=/opt/bin/host-rkt
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
#!/bin/sh
# This is bind mounted into the kubelet rootfs and all rkt shell-outs go
# through this rkt wrapper. It essentially enters the host mount namespace
# (which it is already in) only for the purpose of breaking out of the chroot
# before calling rkt. It makes things like rkt gc work and avoids bind mounting
# in certain rkt filesystem dependancies into the kubelet rootfs. This can
# eventually be obviated when the write-api stuff gets upstream and rkt gc is
# through the api-server. Related issue:
# https://github.com/coreos/rkt/issues/2878
exec nsenter -m -u -i -n -p -t 1 -- /usr/bin/rkt "\$@"
EOF
    fi


    local TEMPLATE=/etc/systemd/system/load-rkt-stage1.service
    if [ ${CONTAINER_RUNTIME} = "rkt" ] && [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Description=Load rkt stage1 images
Documentation=http://github.com/coreos/rkt
Requires=network-online.target
After=network-online.target
Before=rkt-api.service

[Service]
RemainAfterExit=yes
Type=oneshot
ExecStart=/usr/bin/rkt fetch /usr/lib/rkt/stage1-images/stage1-coreos.aci /usr/lib/rkt/stage1-images/stage1-fly.aci  --insecure-options=image

[Install]
RequiredBy=rkt-api.service
EOF
    fi

    local TEMPLATE=/etc/systemd/system/rkt-api.service
    if [ ${CONTAINER_RUNTIME} = "rkt" ] && [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Before=kubelet.service

[Service]
ExecStart=/usr/bin/rkt api-service
Restart=always
RestartSec=10

[Install]
RequiredBy=kubelet.service
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-proxy.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
  annotations:
    rkt.alpha.kubernetes.io/stage1-name-override: coreos.com/rkt/stage1-fly
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - proxy
    - --master=http://127.0.0.1:8080
    - --cluster-cidr=${POD_NETWORK}
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
    - mountPath: /var/run/dbus
      name: dbus
      readOnly: false
  volumes:
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
  - hostPath:
      path: /var/run/dbus
    name: dbus
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-apiserver.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-apiserver
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - apiserver
    - --bind-address=0.0.0.0
    - --etcd-servers=${ETCD_ENDPOINTS}
    - --allow-privileged=true
    - --service-cluster-ip-range=${SERVICE_IP_RANGE}
    - --secure-port=443
    - --advertise-address=${ADVERTISE_IP}
    - --admission-control=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota
    - --tls-cert-file=/etc/kubernetes/ssl/apiserver.pem
    - --tls-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --client-ca-file=/etc/kubernetes/ssl/ca.pem
    - --service-account-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --runtime-config=extensions/v1beta1/networkpolicies=true,batch/v2alpha1=true
    - --anonymous-auth=false
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        port: 8080
        path: /healthz
      initialDelaySeconds: 15
      timeoutSeconds: 15
    ports:
    - containerPort: 443
      hostPort: 443
      name: https
    - containerPort: 8080
      hostPort: 8080
      name: local
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-controller-manager.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - name: kube-controller-manager
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - controller-manager
    - --master=http://127.0.0.1:8080
    - --leader-elect=true
    - --service-account-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --root-ca-file=/etc/kubernetes/ssl/ca.pem
    resources:
      requests:
        cpu: 200m
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10252
      initialDelaySeconds: 15
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  hostNetwork: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-scheduler.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-scheduler
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - scheduler
    - --master=http://127.0.0.1:8080
    - --leader-elect=true
    resources:
      requests:
        cpu: 100m
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10251
      initialDelaySeconds: 15
      timeoutSeconds: 15
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-de.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
spec:
  strategy:
    rollingUpdate:
      maxSurge: 10%
      maxUnavailable: 0
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      containers:
      - name: kubedns
        image: gcr.io/google_containers/kubedns-amd64:1.9
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        livenessProbe:
          httpGet:
            path: /healthz-kubedns
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /readiness
            port: 8081
            scheme: HTTP
          initialDelaySeconds: 3
          timeoutSeconds: 5
        args:
        - --domain=cluster.local.
        - --dns-port=10053
        - --config-map=kube-dns
        # This should be set to v=2 only after the new image (cut from 1.5) has
        # been released, otherwise we will flood the logs.
        - --v=2
        env:
        - name: PROMETHEUS_PORT
          value: "10055"
        ports:
        - containerPort: 10053
          name: dns-local
          protocol: UDP
        - containerPort: 10053
          name: dns-tcp-local
          protocol: TCP
        - containerPort: 10055
          name: metrics
          protocol: TCP
      - name: dnsmasq
        image: gcr.io/google_containers/kube-dnsmasq-amd64:1.4
        livenessProbe:
          httpGet:
            path: /healthz-dnsmasq
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - --cache-size=1000
        - --no-resolv
        - --server=127.0.0.1#10053
        - --log-facility=-
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        # see: https://github.com/kubernetes/kubernetes/issues/29055 for details
        resources:
          requests:
            cpu: 150m
            memory: 10Mi
      - name: dnsmasq-metrics
        image: gcr.io/google_containers/dnsmasq-metrics-amd64:1.0
        livenessProbe:
          httpGet:
            path: /metrics
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - --v=2
        - --logtostderr
        ports:
        - containerPort: 10054
          name: metrics
          protocol: TCP
        resources:
          requests:
            memory: 10Mi
      - name: healthz
        image: gcr.io/google_containers/exechealthz-amd64:1.2
        resources:
          limits:
            memory: 50Mi
          requests:
            cpu: 10m
            memory: 50Mi
        args:
        - --cmd=nslookup kubernetes.default.svc.cluster.local 127.0.0.1 >/dev/null
        - --url=/healthz-dnsmasq
        - --cmd=nslookup kubernetes.default.svc.cluster.local 127.0.0.1:10053 >/dev/null
        - --url=/healthz-kubedns
        - --port=8080
        - --quiet
        ports:
        - containerPort: 8080
          protocol: TCP
      dnsPolicy: Default

EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-autoscaler-de.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kube-dns-autoscaler
  namespace: kube-system
  labels:
    k8s-app: kube-dns-autoscaler
    kubernetes.io/cluster-service: "true"
spec:
  template:
    metadata:
      labels:
        k8s-app: kube-dns-autoscaler
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      containers:
      - name: autoscaler
        image: gcr.io/google_containers/cluster-proportional-autoscaler-amd64:1.0.0
        resources:
            requests:
                cpu: "20m"
                memory: "10Mi"
        command:
          - /cluster-proportional-autoscaler
          - --namespace=kube-system
          - --configmap=kube-dns-autoscaler
          - --mode=linear
          - --target=Deployment/kube-dns
          - --default-params={"linear":{"coresPerReplica":256,"nodesPerReplica":16,"min":1}}
          - --logtostderr=true
          - --v=2
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-svc.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: ${DNS_SERVICE_IP}
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/heapster-influx-graphana-de.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: heapster-v1.3.0-beta.0
  namespace: kube-system
  labels:
    k8s-app: heapster
    kubernetes.io/cluster-service: "true"
    version: v1.3.0-beta.0
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: heapster
      version: v1.3.0-beta.0
  template:
    metadata:
      labels:
        k8s-app: heapster
        version: v1.3.0-beta.0
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      containers:
        - image: gcr.io/google_containers/heapster:v1.3.0-beta.0
          name: heapster
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8082
              scheme: HTTP
            initialDelaySeconds: 180
            timeoutSeconds: 5
          command:
            - /heapster
            - --source=kubernetes.summary_api:''
            - --sink=influxdb:http://monitoring-influxdb:8086
        - image: gcr.io/google_containers/addon-resizer:1.6
          name: heapster-nanny
          resources:
            limits:
              cpu: 50m
              memory: 90Mi
            requests:
              cpu: 50m
              memory: 90Mi
          env:
            - name: MY_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: MY_POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          command:
            - /pod_nanny
            - --cpu=80m
            - --extra-cpu=4m
            - --memory=200Mi
            - --extra-memory=4Mi
            - --threshold=5
            - --deployment=heapster-v1.3.0-beta.0
            - --container=heapster
            - --poll-period=300000
            - --estimator=exponential

---

apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: monitoring-influxdb
  namespace: kube-system
spec:
  replicas: 1
  template:
    metadata:
      labels:
        task: monitoring
        k8s-app: influxdb
    spec:
      containers:
      - name: influxdb
        image: gcr.io/google_containers/heapster-influxdb:v0.13.0
        volumeMounts:
        - mountPath: /data
          name: influxdb-storage
      volumes:
      - name: influxdb-storage
        emptyDir: {}

---

apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: monitoring-grafana
  namespace: kube-system
spec:
  replicas: 1
  template:
    metadata:
      labels:
        task: monitoring
        k8s-app: grafana
    spec:
      containers:
      - name: grafana
        image: gcr.io/google_containers/heapster-grafana:v2.6.0-2
        ports:
          - containerPort: 3000
            protocol: TCP
        volumeMounts:
        - mountPath: /var
          name: grafana-storage
        env:
        - name: INFLUXDB_HOST
          value: monitoring-influxdb
        - name: GRAFANA_PORT
          value: "3000"
          # The following env variables are required to make Grafana accessible via
          # the kubernetes api-server proxy. On production clusters, we recommend
          # removing these env variables, setup auth for grafana, and expose the grafana
          # service using a LoadBalancer or a public IP.
        - name: GF_AUTH_BASIC_ENABLED
          value: "false"
        - name: GF_AUTH_ANONYMOUS_ENABLED
          value: "true"
        - name: GF_AUTH_ANONYMOUS_ORG_ROLE
          value: Admin
        - name: GF_SERVER_ROOT_URL
          # If you're only using the API Server proxy, set this value instead:
          # value: /api/v1/proxy/namespaces/kube-system/services/monitoring-grafana/
          value: /api/v1/proxy/namespaces/kube-system/services/monitoring-grafana/
      volumes:
      - name: grafana-storage
        emptyDir: {}
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/heapster-influx-graphana-svc.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
kind: Service
apiVersion: v1
metadata:
  name: heapster
  namespace: kube-system
  labels:
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "Heapster"
spec:
  ports:
    - port: 80
      targetPort: 8082
  selector:
    k8s-app: heapster

---

apiVersion: v1
kind: Service
metadata:
  labels:
    task: monitoring
    # For use as a Cluster add-on (https://github.com/kubernetes/kubernetes/tree/master/cluster/addons)
    # If you are NOT using this as an addon, you should comment out this line.
    kubernetes.io/cluster-service: 'true'
    kubernetes.io/name: monitoring-influxdb
  name: monitoring-influxdb
  namespace: kube-system
spec:
  ports:
  - port: 8086
    targetPort: 8086
  selector:
    k8s-app: influxdb

---

apiVersion: v1
kind: Service
metadata:
  labels:
    # For use as a Cluster add-on (https://github.com/kubernetes/kubernetes/tree/master/cluster/addons)
    # If you are NOT using this as an addon, you should comment out this line.
    kubernetes.io/cluster-service: 'true'
    kubernetes.io/name: monitoring-grafana
  name: monitoring-grafana
  namespace: kube-system
spec:
  # In a production setup, we recommend accessing Grafana through an external Loadbalancer
  # or through a public IP.
  # type: LoadBalancer
  # You could also use NodePort to expose the service at a randomly-generated port
  # type: NodePort
  ports:
  - port: 80
    targetPort: 3000
  selector:
    k8s-app: grafana
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dashboard-de.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kubernetes-dashboard
  namespace: kube-system
  labels:
    k8s-app: kubernetes-dashboard
    kubernetes.io/cluster-service: "true"
spec:
  selector:
    matchLabels:
      k8s-app: kubernetes-dashboard
  template:
    metadata:
      labels:
        k8s-app: kubernetes-dashboard
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      containers:
      - name: kubernetes-dashboard
        image: gcr.io/google_containers/kubernetes-dashboard-amd64:v1.5.0
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 100m
            memory: 50Mi
          requests:
            cpu: 100m
            memory: 50Mi
        ports:
        - containerPort: 9090
        livenessProbe:
          httpGet:
            path: /
            port: 9090
          initialDelaySeconds: 30
          timeoutSeconds: 30
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dashboard-svc.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-dashboard
  namespace: kube-system
  labels:
    k8s-app: kubernetes-dashboard
    kubernetes.io/cluster-service: "true"
spec:
  selector:
    k8s-app: kubernetes-dashboard
  ports:
  - port: 80
    targetPort: 9090
EOF
    fi
	
	local TEMPLATE=/srv/kubernetes/manifests/kube-lego.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Namespace
metadata:
  name: kube-lego

---

apiVersion: v1
metadata:
  name: kube-lego
  namespace: kube-lego
data:
  # modify this to specify your address
  lego.email: "${EMAIL}"
  # configure letencrypt's production api
  lego.url: "https://acme-v01.api.letsencrypt.org/directory"
kind: ConfigMap

---

apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kube-lego
  namespace: kube-lego
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: kube-lego
    spec:
      containers:
      - name: kube-lego
        image: jetstack/kube-lego:0.1.3
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        env:
        - name: LEGO_EMAIL
          valueFrom:
            configMapKeyRef:
              name: kube-lego
              key: lego.email
        - name: LEGO_URL
          valueFrom:
            configMapKeyRef:
              name: kube-lego
              key: lego.url
        - name: LEGO_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: LEGO_POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          timeoutSeconds: 1
EOF
    fi

	local TEMPLATE=/srv/kubernetes/manifests/ingress-nginx.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << 'EOF' > $TEMPLATE
apiVersion: v1
kind: Namespace
metadata:
  name: nginx-ingress

---

apiVersion: v1
data:
  proxy-connect-timeout: "15"
  proxy-read-timeout: "600"
  proxy-send-imeout: "600"
  hsts-include-subdomains: "false"
  proxy-body-size: "1064m"
  server-name-hash-bucket-size: "256"
  use-http2: "true"
  use-gzip: "true"
kind: ConfigMap
metadata:
  namespace: nginx-ingress
  name: nginx

---

apiVersion: extensions/v1beta1
kind: DaemonSet
metadata:
  name: nginx
  namespace: nginx-ingress
  labels:
    k8s-app: nginx-ingress-lb
spec:
  template:
    metadata:
      labels:
        name: nginx
        k8s-app: nginx-ingress-lb
    spec:
      containers:
      - image: quay.io/promaethius/ingress
        name: nginx
        imagePullPolicy: Always
        env:
          - name: POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
        readinessProbe:
          httpGet:
            path: /healthz
            port: 10254
            scheme: HTTP
        livenessProbe:
          httpGet:
            path: /healthz
            port: 10254
            scheme: HTTP
          initialDelaySeconds: 10
          timeoutSeconds: 1
        ports:
        - name: http
          protocol: TCP
          containerPort: 80
          hostPort: 80
        - name: https
          protocol: TCP
          containerPort: 443
          hostPort: 443
        args:
        - /nginx-ingress-controller
        - --default-backend-service=$(POD_NAMESPACE)/default-http-backend
        - --configmap=$(POD_NAMESPACE)/nginx-load-balancer-conf
      nodeSelector:
        ingress: "true"
EOF
    fi
	
	local TEMPLATE=/srv/kubernetes/manifests/default-backend.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: default-http-backend
  namespace: nginx-ingress
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: default-http-backend
    spec:
      containers:
      - name: default-http-backend
        # Any image is permissable as long as:
        # 1. It serves a 404 page at /
        # 2. It serves 200 on a /healthz endpoint
        image: gcr.io/google_containers/defaultbackend:1.0
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 30
          timeoutSeconds: 5
        ports:
        - containerPort: 8080
        resources:
          limits:
            cpu: 10m
            memory: 20Mi
          requests:
            cpu: 10m
            memory: 20Mi

---

apiVersion: v1
kind: Service
metadata:
  name: default-http-backend
  namespace: nginx-ingress
spec:
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
  selector:
    app: default-http-backend
EOF
    fi	

    local TEMPLATE=/etc/flannel/options.env
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
FLANNELD_IFACE=$ADVERTISE_IP
FLANNELD_ETCD_ENDPOINTS=$ETCD_ENDPOINTS
EOF
    fi

    local TEMPLATE=/etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf.conf
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
EOF
    fi

    local TEMPLATE=/etc/systemd/system/docker.service.d/40-flannel.conf
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Requires=flanneld.service
After=flanneld.service
[Service]
EnvironmentFile=/etc/kubernetes/cni/docker_opts_cni.env
EOF
    fi

    local TEMPLATE=/etc/kubernetes/cni/docker_opts_cni.env
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
DOCKER_OPT_BIP=""
DOCKER_OPT_IPMASQ=""
EOF
    fi

    local TEMPLATE=/etc/kubernetes/cni/net.d/10-flannel.conf
    if [ "${USE_CALICO}" = "false" ] && [ ! -f "${TEMPLATE}" ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
    "name": "podnet",
    "type": "flannel",
    "delegate": {
        "isDefaultGateway": true
    }
}
EOF
    fi

	local TEMPLATE=/srv/kubernetes/manifests/calico-config.yaml
    if [ "${USE_CALICO}" = "true" ] && [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << EOF > $TEMPLATE
# This ConfigMap is used to configure a self-hosted Calico installation.
kind: ConfigMap
apiVersion: v1
metadata:
  name: calico-config
  namespace: kube-system
data:
  # Configure this with the location of your etcd cluster.
  etcd_endpoints: "${ETCD_ENDPOINTS}"

  # Configure the Calico backend to use.
  calico_backend: "none"

  # The CNI network configuration to install on each node.
  cni_network_config: |-
    {
        "name": "calico",
        "type": "flannel",
        "delegate": {
          "type": "calico",
          "etcd_endpoints": "__ETCD_ENDPOINTS__",
          "etcd_key_file": "__ETCD_KEY_FILE__",
          "etcd_cert_file": "__ETCD_CERT_FILE__",
          "etcd_ca_cert_file": "__ETCD_CA_CERT_FILE__",
          "log_level": "info",
          "policy": {
            "type": "k8s",
            "k8s_api_root": "https://__KUBERNETES_SERVICE_HOST__:__KUBERNETES_SERVICE_PORT__",
            "k8s_auth_token": "__SERVICEACCOUNT_TOKEN__"
          },
          "kubernetes": {
              "kubeconfig": "/etc/kubernetes/cni/net.d/__KUBECONFIG_FILENAME__"
          }
        }
    }

  # If you're using TLS enabled etcd uncomment the following.
  # You must also populate the Secret below with these files.
  etcd_ca: ""   # "/calico-secrets/etcd-ca"
  etcd_cert: "" # "/calico-secrets/etcd-cert"
  etcd_key: ""  # "/calico-secrets/etcd-key"

---

# The following contains k8s Secrets for use with a TLS enabled etcd cluster.
# For information on populating Secrets, see http://kubernetes.io/docs/user-guide/secrets/
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: calico-etcd-secrets
  namespace: kube-system
data:
  # Populate the following files with etcd TLS configuration if desired, but leave blank if
  # not using TLS for etcd.
  # This self-hosted install expects three files with the following names.  The values
  # should be base64 encoded strings of the entire contents of each file.
  # etcd-key: null
  # etcd-cert: null
  # etcd-ca: null
EOF
	fi

	local TEMPLATE=/srv/kubernetes/manifests/calico.yaml
    if [ "${USE_CALICO}" = "true" ] && [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << 'EOF' > $TEMPLATE

# This manifest installs the calico/node container, as well
# as the Calico CNI plugins and network config on
# each master and worker node in a Kubernetes cluster.
kind: DaemonSet
apiVersion: extensions/v1beta1
metadata:
  name: calico-node
  namespace: kube-system
  labels:
    k8s-app: calico-node
spec:
  selector:
    matchLabels:
      k8s-app: calico-node
  template:
    metadata:
      labels:
        k8s-app: calico-node
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: |
          [{"key": "dedicated", "value": "master", "effect": "NoSchedule" },
           {"key":"CriticalAddonsOnly", "operator":"Exists"}]
    spec:
      hostNetwork: true
      containers:
        # Runs calico/node container on each Kubernetes node.  This
        # container programs network policy and routes on each
        # host.
        - name: calico-node
          image: quay.io/calico/node:v1.0.1
          command: ["/bin/sh", "-c"]
          args: ["mount -o remount,rw /proc/sys && start_runit"]
          env:
            # The location of the Calico etcd cluster.
            - name: ETCD_ENDPOINTS
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_endpoints
            # Choose the backend to use.
            - name: CALICO_NETWORKING_BACKEND
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: calico_backend
            # Disable file logging so `kubectl logs` works.
            - name: CALICO_DISABLE_FILE_LOGGING
              value: "true"
            # Don't configure a default pool.  This is done by the Job
            # below.
            - name: NO_DEFAULT_POOLS
              value: "true"
            - name: FELIX_LOGSEVERITYSCREEN
              value: "info"
            # Location of the CA certificate for etcd.
            - name: ETCD_CA_CERT_FILE
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_ca
            # Location of the client key for etcd.
            - name: ETCD_KEY_FILE
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_key
            # Location of the client certificate for etcd.
            - name: ETCD_CERT_FILE
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_cert
            # Auto-detect the BGP IP address.
            - name: IP
              value: ""
          securityContext:
            privileged: true
          volumeMounts:
            - mountPath: /lib/modules
              name: lib-modules
              readOnly: false
            - mountPath: /var/run/calico
              name: var-run-calico
              readOnly: false
            - mountPath: /calico-secrets
              name: etcd-certs
            #- mountPath: /etc/resolv.conf
            #  name: dns
            #  readOnly: true
        # This container installs the Calico CNI binaries
        # and CNI network config file on each node.
        - name: install-cni
          image: quay.io/calico/cni:v1.5.5
          command: ["/bin/sh", "-c"]
          args: ["export CNI_NETWORK_CONFIG=$(cat /host/cni_network_config/config.conf) && /install-cni.sh"]
          env:
            # The location of the Calico etcd cluster.
            - name: ETCD_ENDPOINTS
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_endpoints
            # CNI configuration filename
            - name: CNI_CONF_NAME
              value: "10-calico.conf"
          securityContext:
            privileged: true
          volumeMounts:
            - mountPath: /host/opt/cni/bin
              name: cni-bin-dir
            - mountPath: /host/etc/cni/net.d
              name: cni-net-dir
            - mountPath: /calico-secrets
              name: etcd-certs
            # The CNI network config to install on each node.
            - mountPath: /host/cni_network_config
              name: cni-config
      volumes:
        # Used by calico/node.
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: var-run-calico
          hostPath:
            path: /var/run/calico
        # Used to install CNI.
        - name: cni-bin-dir
          hostPath:
            path: /opt/cni/bin
        - name: cni-net-dir
          hostPath:
            path: /etc/kubernetes/cni/net.d
        # Mount in the etcd TLS secrets.
        - name: etcd-certs
          secret:
            secretName: calico-etcd-secrets
        - name: cni-config
          configMap:
            name: calico-config
            items:
            - key: cni_network_config
              path: config.conf
        - name: dns
          hostPath:
            path: /run/systemd/resolve/resolv.conf

---

# This manifest deploys the Calico policy controller on Kubernetes.
# See https://github.com/projectcalico/k8s-policy
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: calico-policy-controller
  namespace: kube-system
  labels:
    k8s-app: calico-policy
  annotations:
    scheduler.alpha.kubernetes.io/critical-pod: ''
    scheduler.alpha.kubernetes.io/tolerations: |
      [{"key": "dedicated", "value": "master", "effect": "NoSchedule" },
       {"key":"CriticalAddonsOnly", "operator":"Exists"}]
spec:
  # The policy controller can only have a single active instance.
  replicas: 1
  strategy:
    type: Recreate
  template:
    metadata:
      name: calico-policy-controller
      namespace: kube-system
      labels:
        k8s-app: calico-policy
    spec:
      # The policy controller must run in the host network namespace so that
      # it isn't governed by policy that would prevent it from working.
      hostNetwork: true
      containers:
        - name: calico-policy-controller
          image: calico/kube-policy-controller:v0.5.1
          env:
            # The location of the Calico etcd cluster.
            - name: ETCD_ENDPOINTS
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_endpoints
            # Location of the CA certificate for etcd.
            - name: ETCD_CA_CERT_FILE
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_ca
            # Location of the client key for etcd.
            - name: ETCD_KEY_FILE
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_key
            # Location of the client certificate for etcd.
            - name: ETCD_CERT_FILE
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_cert
            # The location of the Kubernetes API.  Use the default Kubernetes
            # service for API access.
            - name: K8S_API
              value: "https://kubernetes.default:443"
            # Since we're running in the host namespace and might not have KubeDNS
            # access, configure the container's /etc/hosts to resolve
            # kubernetes.default to the correct service clusterIP.
            - name: CONFIGURE_ETC_HOSTS
              value: "true"
          volumeMounts:
            # Mount in the etcd TLS secrets.
            - mountPath: /calico-secrets
              name: etcd-certs
      volumes:
        # Mount in the etcd TLS secrets.
        - name: etcd-certs
          secret:
            secretName: calico-etcd-secrets
EOF
    fi
}

function install_kubectl {

mkdir -p /opt/bin

curl -o /opt/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/${K8S_VER::-9}/bin/linux/amd64/kubectl
chmod +x /opt/bin/kubectl

kubectl config set-cluster default-cluster --server=https://controller.videaris.com --certificate-authority=/etc/kubernetes/ssl/ca.pem
kubectl config set-credentials default-admin --certificate-authority=/etc/kubernetes/ssl/ca.pem --client-key=/etc/kubernetes/ssl/admin-key.pem --client-certificate=/etc/kubernetes/ssl/admin.pem
kubectl config set-context default-system --cluster=default-cluster --user=default-admin
kubectl config use-context default-system

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


	#Create Templates
	local TEMPLATE=/srv/kubernetes/manifests/ceph-osd.yaml
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << 'EOF' > $TEMPLATE
---
kind: DaemonSet
apiVersion: extensions/v1beta1
metadata:
  name: ceph-osd
  namespace: ceph
  labels:
    app: ceph
    daemon: osd
spec:
  template:
    metadata:
      labels:
        app: ceph
        daemon: osd
    spec:
      nodeSelector:
        node-type: storage
      volumes:
        - name: devices
          hostPath:
            path: /dev
        - name: ceph
#          emptyDir: {}
          hostPath:
            path: /opt/ceph
        - name: ceph-conf
          secret:
            secretName: ceph-conf-combined
        - name: ceph-bootstrap-osd-keyring
          secret:
            secretName: ceph-bootstrap-osd-keyring
        - name: ceph-bootstrap-mds-keyring
          secret:
            secretName: ceph-bootstrap-mds-keyring
        - name: ceph-bootstrap-rgw-keyring
          secret:
            secretName: ceph-bootstrap-rgw-keyring
        - name: osd-directory
#          emptyDir: {}
          hostPath:
            path: /home/core/data/ceph/osd
      containers:
        - name: osd-pod
          image: ceph/daemon:latest
          imagePullPolicy: Always
          volumeMounts:
            - name: devices
              mountPath: /dev
            - name: ceph
              mountPath: /var/lib/ceph
            - name: ceph-conf
              mountPath: /etc/ceph
            - name: ceph-bootstrap-osd-keyring
              mountPath: /var/lib/ceph/bootstrap-osd
            - name: ceph-bootstrap-mds-keyring
              mountPath: /var/lib/ceph/bootstrap-mds
            - name: ceph-bootstrap-rgw-keyring
              mountPath: /var/lib/ceph/bootstrap-rgw
            - name: osd-directory
              mountPath: /var/lib/ceph/osd
          securityContext:
            privileged: true
          env:
            - name: CEPH_DAEMON
              value: osd_directory
            - name: KV_TYPE
              value: k8s
            - name: CLUSTER
              value: ceph
            - name: CEPH_GET_ADMIN_KEY
              value: "1"
          livenessProbe:
              tcpSocket:
                port: 6800
              initialDelaySeconds: 60
              timeoutSeconds: 5
          readinessProbe:
              tcpSocket:
                port: 6800
              timeoutSeconds: 5
          resources:
            requests:
              memory: "512Mi"
              cpu: "1000m"
            limits:
              memory: "1024Mi"
              cpu: "2000m"
EOF
	fi
	
	local TEMPLATE=/srv/kubernetes/manifests/ceph-mon.yaml
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << EOF > $TEMPLATE
---
apiVersion: v1
kind: Service
metadata:
  name: ceph-mon
  namespace: ceph
  labels:
    app: ceph
    daemon: mon
spec:
  ports:
  - port: 6789
    protocol: TCP
    targetPort: 6789
  selector:
    app: ceph
    daemon: mon
  clusterIP: None
---
kind: DaemonSet
apiVersion: extensions/v1beta1
metadata:
  labels:
    app: ceph
    daemon: mon
  name: ceph-mon
  namespace: ceph
spec:
  template:
    metadata:
      name: ceph-mon
      namespace: ceph
      labels:
        app: ceph
        daemon: mon
    spec:
      nodeSelector:
        node-type: storage
      serviceAccount: default
      volumes:
        - name: ceph-conf
          secret:
            secretName: ceph-conf-combined
        - name: ceph-bootstrap-osd-keyring
          secret:
            secretName: ceph-bootstrap-osd-keyring
        - name: ceph-bootstrap-mds-keyring
          secret:
            secretName: ceph-bootstrap-mds-keyring
        - name: ceph-bootstrap-rgw-keyring
          secret:
            secretName: ceph-bootstrap-rgw-keyring
        - name: ceph-data
          hostPath:
            path: /home/core/data/ceph/mon
      containers:
        - name: ceph-mon
          image: ceph/daemon:latest
          imagePullPolicy: Always
          securityContext:
            privileged: true
          lifecycle:
            preStop:
                exec:
                  # remove the mon on Pod stop.
                  command:
                    - "/remove-mon.sh"
          ports:
            - containerPort: 6789
          env:
            - name: CEPH_DAEMON
              value: MON
            - name: KV_TYPE
              value: k8s
            - name: NETWORK_AUTO_DETECT
              value: "0"
            - name: CLUSTER
              value: ceph
            - name: MON_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: CEPH_PUBLIC_NETWORK
              value: ${POD_NETWORK}
            - name: CEPH_CLUSTER_NETWORK
              value: ${POD_NETWORK}
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          volumeMounts:
            - name: ceph-conf
              mountPath: /etc/ceph
            - name: ceph-bootstrap-osd-keyring
              mountPath: /var/lib/ceph/bootstrap-osd
            - name: ceph-bootstrap-mds-keyring
              mountPath: /var/lib/ceph/bootstrap-mds
            - name: ceph-bootstrap-rgw-keyring
              mountPath: /var/lib/ceph/bootstrap-rgw
            - name: ceph-data
              mountPath: /var/lib/ceph
          livenessProbe:
              tcpSocket:
                port: 6789
              initialDelaySeconds: 60
              timeoutSeconds: 5
          readinessProbe:
              tcpSocket:
                port: 6789
              timeoutSeconds: 5
---
kind: Deployment
apiVersion: extensions/v1beta1
metadata:
  labels:
    app: ceph
    daemon: moncheck
  name: ceph-mon-check
  namespace: ceph
spec:
  replicas: 1
  template:
    metadata:
      name: ceph-mon
      namespace: ceph
      labels:
        app: ceph
        daemon: moncheck
    spec:
      serviceAccount: default
      volumes:
        - name: ceph-conf
          secret:
            secretName: ceph-conf-combined
        - name: ceph-bootstrap-osd-keyring
          secret:
            secretName: ceph-bootstrap-osd-keyring
        - name: ceph-bootstrap-mds-keyring
          secret:
            secretName: ceph-bootstrap-mds-keyring
        - name: ceph-bootstrap-rgw-keyring
          secret:
            secretName: ceph-bootstrap-rgw-keyring
      containers:
        - name: ceph-mon
          image: ceph/daemon:latest
          imagePullPolicy: Always
          securityContext:
            privileged: true
          ports:
            - containerPort: 6789
          env:
            - name: CEPH_DAEMON
              value: MON_HEALTH
            - name: KV_TYPE
              value: k8s
            - name: MON_IP_AUTO_DETECT
              value: "1"
            - name: CLUSTER
              value: ceph
          volumeMounts:
            - name: ceph-conf
              mountPath: /etc/ceph
            - name: ceph-bootstrap-osd-keyring
              mountPath: /var/lib/ceph/bootstrap-osd
            - name: ceph-bootstrap-mds-keyring
              mountPath: /var/lib/ceph/bootstrap-mds
            - name: ceph-bootstrap-rgw-keyring
              mountPath: /var/lib/ceph/bootstrap-rgw
          resources:
            requests:
              memory: "5Mi"
              cpu: "250m"
            limits:
              memory: "50Mi"
              cpu: "500m"
EOF
	fi
	
	local TEMPLATE=/srv/kubernetes/manifests/ceph-mds.yaml
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << 'EOF' > $TEMPLATE
---
kind: Deployment
apiVersion: extensions/v1beta1
metadata:
  labels:
    app: ceph
    daemon: mds
  name: ceph-mds
  namespace: ceph
spec:
  replicas: 1
  template:
    metadata:
      name: ceph-mds
      namespace: ceph
      labels:
        app: ceph
        daemon: mds
    spec:
      nodeSelector:
        node-type: storage
      serviceAccount: default
      volumes:
        - name: ceph-conf
          secret:
            secretName: ceph-conf-combined
        - name: ceph-bootstrap-osd-keyring
          secret:
            secretName: ceph-bootstrap-osd-keyring
        - name: ceph-bootstrap-mds-keyring
          secret:
            secretName: ceph-bootstrap-mds-keyring
        - name: ceph-bootstrap-rgw-keyring
          secret:
            secretName: ceph-bootstrap-rgw-keyring
      containers:
        - name: ceph-mds
          image: ceph/daemon:latest
          ports:
            - containerPort: 6800
          env:
            - name: CEPH_DAEMON
              value: MDS
            - name: CEPHFS_CREATE
              value: "1"
            - name: KV_TYPE
              value: k8s
            - name: CLUSTER
              value: ceph
          volumeMounts:
            - name: ceph-conf
              mountPath: /etc/ceph
            - name: ceph-bootstrap-osd-keyring
              mountPath: /var/lib/ceph/bootstrap-osd
            - name: ceph-bootstrap-mds-keyring
              mountPath: /var/lib/ceph/bootstrap-mds
            - name: ceph-bootstrap-rgw-keyring
              mountPath: /var/lib/ceph/bootstrap-rgw
          livenessProbe:
              tcpSocket:
                port: 6800
              initialDelaySeconds: 60
              timeoutSeconds: 5
          readinessProbe:
              tcpSocket:
                port: 6800
              timeoutSeconds: 5
          resources:
            requests:
              memory: "10Mi"
              cpu: "250m"
            limits:
              memory: "50Mi"
              cpu: "500m"
EOF
	fi
	
	local TEMPLATE=/home/core/generator/templates/ceph/admin.keyring.tmpl
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << 'EOF' > $TEMPLATE
[client.admin]
  key = {{ $key }}
  auid = 0
  caps mds = "allow"
  caps mon = "allow *"
  caps osd = "allow *"
EOF
	fi
	
	local TEMPLATE=/home/core/generator/templates/ceph/bootstrap.keyring.tmpl
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << 'EOF' > $TEMPLATE
[client.bootstrap-{{ $service }}]
  key = {{ $key }}
  caps mon = "allow profile bootstrap-{{ $service }}"
EOF
	fi
	
	local TEMPLATE=/home/core/generator/templates/ceph/ceph.conf.tmpl
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << 'EOF' > $TEMPLATE
[global]
fsid = ${fsid:?}
cephx = ${auth_cephx:-"true"}
cephx_require_signatures = ${auth_cephx_require_signatures:-"false"}
cephx_cluster_require_signatures = ${auth_cephx_cluster_require_signatures:-"true"}
cephx_service_require_signatures = ${auth_cephx_service_require_signatures:-"false"}

# auth
max_open_files = ${global_max_open_files:-"131072"}
osd_pool_default_pg_num = ${global_osd_pool_default_pg_num:-"128"}
osd_pool_default_pgp_num = ${global_osd_pool_default_pgp_num:-"128"}
osd_pool_default_size = ${global_osd_pool_default_size:-"3"}
osd_pool_default_min_size = ${global_osd_pool_default_min_size:-"1"}

mon_osd_full_ratio = ${global_mon_osd_full_ratio:-".95"}
mon_osd_nearfull_ratio = ${global_mon_osd_nearfull_ratio:-".85"}

mon_host = ${global_mon_host:-'ceph-mon'}

[mon]
mon_osd_down_out_interval = ${mon_mon_osd_down_out_interval:-"600"}
mon_osd_min_down_reporters = ${mon_mon_osd_min_down_reporters:-"4"}
mon_clock_drift_allowed = ${mon_mon_clock_drift_allowed:-".15"}
mon_clock_drift_warn_backoff = ${mon_mon_clock_drift_warn_backoff:-"30"}
mon_osd_report_timeout = ${mon_mon_osd_report_timeout:-"300"}


[osd]
journal_size = ${osd_journal_size:-"100"}
cluster_network = ${osd_cluster_network:-'10.244.0.0/16'}
public_network = ${osd_public_network:-'10.244.0.0/16'}
osd_mkfs_type = ${osd_osd_mkfs_type:-"xfs"}
osd_mkfs_options_xfs = ${osd_osd_mkfs_options_xfs:-"-f -i size=2048"}
osd_mon_heartbeat_interval = ${osd_osd_mon_heartbeat_interval:-"30"}
osd_max_object_name_len = ${osd_max_object_name_len:-"256"}

#crush
osd_pool_default_crush_rule = ${osd_pool_default_crush_rule:-"0"}
osd_crush_update_on_start = ${osd_osd_crush_update_on_start:-"true"}

#backend
osd_objectstore = ${osd_osd_objectstore:-"filestore"}

#performance tuning
filestore_merge_threshold = ${osd_filestore_merge_threshold:-"40"}
filestore_split_multiple = ${osd_filestore_split_multiple:-"8"}
osd_op_threads = ${osd_osd_op_threads:-"8"}
filestore_op_threads = ${osd_filestore_op_threads:-"8"}
filestore_max_sync_interval = ${osd_filestore_max_sync_interval:-"5"}
osd_max_scrubs = ${osd_osd_max_scrubs:-"1"}


#recovery tuning
osd_recovery_max_active = ${osd_osd_recovery_max_active:-"5"}
osd_max_backfills = ${osd_osd_max_backfills:-"2"}
osd_recovery_op_priority = ${osd_osd_recovery_op_priority:-"2"}
osd_client_op_priority = ${osd_osd_client_op_priority:-"63"}
osd_recovery_max_chunk = ${osd_osd_recovery_max_chunk:-"1048576"}
osd_recovery_threads = ${osd_osd_recovery_threads:-"1"}

#ports
ms_bind_port_min = ${osd_ms_bind_port_min:-"6800"}
ms_bind_port_max = ${osd_ms_bind_port_max:-"7100"}

[client]
rbd_cache_enabled = ${client_rbd_cache_enabled:-"true"}
rbd_cache_writethrough_until_flush = ${client_rbd_cache_writethrough_until_flush:-"true"}
rbd_default_features = ${client_rbd_default_features:-"1"}

[mds]
mds_cache_size = ${mds_mds_cache_size:-"100000"}
EOF
	fi
	
	local TEMPLATE=/home/core/generator/templates/ceph/mon.keyring.tmpl
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << 'EOF' > $TEMPLATE
[mon.]
  key = {{ $key }}
  caps mon = "allow *"
EOF
	fi
	
	local TEMPLATE=/home/core/generator/ceph-key.py
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << 'EOF' > $TEMPLATE
#!/bin/python
import os
import struct
import time
import base64

key = os.urandom(16)
header = struct.pack(
    '<hiih',
    1,                 # le16 type: CEPH_CRYPTO_AES
    int(time.time()),  # le32 created: seconds
    0,                 # le32 created: nanoseconds,
    len(key),          # le16: len(key)
)
print(base64.b64encode(header + key).decode('ascii'))
EOF
	fi
	
	local TEMPLATE=/home/core/generator/generate_secrets.sh
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << 'EOF' > $TEMPLATE
#!/bin/bash

gen-fsid() {
  echo "$(uuidgen)"
}

gen-ceph-conf-raw() {
  fsid=${1:?}
  shift
  conf=$(sigil -p -f templates/ceph/ceph.conf.tmpl "fsid=${fsid}" $@)
  echo "${conf}"
}

gen-ceph-conf() {
  fsid=${1:?}
  shift
  conf=$(sigil -p -f templates/ceph/ceph.conf.tmpl "fsid=${fsid}" $@)
  echo "${conf}"
}

gen-admin-keyring() {
  key=$(python ceph-key.py)
  keyring=$(sigil -f templates/ceph/admin.keyring.tmpl "key=${key}")
  echo "${keyring}"
}

gen-mon-keyring() {
  key=$(python ceph-key.py)
  keyring=$(sigil -f templates/ceph/mon.keyring.tmpl "key=${key}")
  echo "${keyring}"
}

gen-combined-conf() {
  fsid=${1:?}
  shift
  conf=$(sigil -p -f templates/ceph/ceph.conf.tmpl "fsid=${fsid}" $@)
  echo "${conf}" > ceph.conf

  key=$(python ceph-key.py)
  keyring=$(sigil -f templates/ceph/admin.keyring.tmpl "key=${key}")
  echo "${key}" > ceph-client-key
  echo "${keyring}" > ceph.client.admin.keyring

  key=$(python ceph-key.py)
  keyring=$(sigil -f templates/ceph/mon.keyring.tmpl "key=${key}")
  echo "${keyring}" > ceph.mon.keyring
}

gen-bootstrap-keyring() {
  service="${1:-osd}"
  key=$(python ceph-key.py)
  bootstrap=$(sigil -f templates/ceph/bootstrap.keyring.tmpl "key=${key}" "service=${service}")
  echo "${bootstrap}"
}

gen-all-bootstrap-keyrings() {
  gen-bootstrap-keyring osd > ceph.osd.keyring
  gen-bootstrap-keyring mds > ceph.mds.keyring
  gen-bootstrap-keyring rgw > ceph.rgw.keyring
}

gen-all() {
  gen-combined-conf $@
  gen-all-bootstrap-keyrings
}


main() {
  set -eo pipefail
  case "$1" in
  fsid)            shift; gen-fsid $@;;
  ceph-conf-raw)            shift; gen-ceph-conf-raw $@;;
  ceph-conf)            shift; gen-ceph-conf $@;;
  admin-keyring)            shift; gen-admin-keyring $@;;
  mon-keyring)            shift; gen-mon-keyring $@;;
  bootstrap-keyring)            shift; gen-bootstrap-keyring $@;;
  combined-conf)               shift; gen-combined-conf $@;;
  all)                         shift; gen-all $@;;
  esac
}

main "$@"
EOF
	chmod +x ${TEMPLATE}
	fi
	
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
	kubectl apply -f /host/manifests/heapster-influx-graphana-de.yaml,/host/manifests/heapster-influx-graphana-svc.yaml
    echo "K8S: Kube-Lego addon"
    kubectl apply -f /host/manifests/kube-lego.yaml
	echo "K8S: NGinx Ingress addon"
    kubectl apply -f /host/manifests/ingress-nginx.yaml,/host/manifests/default-backend.yaml
    echo "K8S: Dashboard addon"
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-de.yaml)" "http://127.0.0.1:8080/apis/extensions/v1beta1/namespaces/kube-system/deployments" > /dev/null
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-svc.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/services" > /dev/null
}

function start_calico {
    echo "Waiting for Kubernetes API..."
    # wait for the API
    until curl --silent "http://127.0.0.1:8080/version/"
    do
        sleep 5
    done
    echo "Deploying Calico"
    kubectl apply -f /host/manifests/calico-config.yaml,/host/manifests/calico.yaml

}

install_kubectl
init_config
init_templates

chmod +x /opt/bin/host-rkt

init_flannel

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
