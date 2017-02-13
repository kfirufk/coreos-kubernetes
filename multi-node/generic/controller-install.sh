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
        cat << EOF > $TEMPLATE
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
  body-size: "1064m"
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
      - image: quay.io/promaethius/nginx-ingress
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
        livenessProbe:
          httpGet:
            path: /healthz
            port: 10249
            scheme: HTTP
          initialDelaySeconds: 30
          timeoutSeconds: 5
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
        - --default-backend-service=nginx-ingress/default-http-backend
        - --nginx-configmap=nginx-ingress/nginx
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

	local TEMPLATE=/etc/kubernetes/manifests/glusterfs.yaml
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << EOF > $TEMPLATE
apiVersion: v1
kind: Namespace
metadata:
  name: filesystem
---
kind: DaemonSet
apiVersion: extensions/v1beta1
metadata:
  name: glusterfs
  namespace: filesystem
  labels:
    glusterfs: daemonset
  annotations:
    description: GlusterFS DaemonSet
    tags: glusterfs
spec:
  template:
    metadata:
      name: glusterfs
      labels:
        glusterfs-node: pod
    spec:
      nodeSelector:
        storagenode: glusterfs
      hostNetwork: true
      containers:
      - image: quay.io/promaethius/glusterfs
        imagePullPolicy: Always
        name: glusterfs
        volumeMounts:
        - name: glusterfs-heketi
          mountPath: "/var/lib/heketi"
        - name: glusterfs-run
          mountPath: "/run"
        - name: glusterfs-lvm
          mountPath: "/run/lvm"
        - name: glusterfs-etc
          mountPath: "/etc/glusterfs"
        - name: glusterfs-logs
          mountPath: "/var/log/glusterfs"
        - name: glusterfs-config
          mountPath: "/var/lib/glusterd"
        - name: glusterfs-dev
          mountPath: "/dev"
        - name: glusterfs-misc
          mountPath: "/var/lib/misc/glusterfsd"
        securityContext:
          privileged: true
        readinessProbe:
          timeoutSeconds: 3
          initialDelaySeconds: 60
          exec:
            command:
            - "/bin/bash"
            - "-c"
            - gluster peer status
        livenessProbe:
          timeoutSeconds: 3
          initialDelaySeconds: 60
          exec:
            command:
            - "/bin/bash"
            - "-c"
            - gluster peer status
      volumes:
      - name: glusterfs-heketi
        hostPath:
          path: "/var/lib/heketi"
      - name: glusterfs-run
      - name: glusterfs-lvm
        hostPath:
          path: "/run/lvm"
      - name: glusterfs-etc
        hostPath:
          path: "/etc/glusterfs"
      - name: glusterfs-logs
        hostPath:
          path: "/var/log/glusterfs"
      - name: glusterfs-config
        hostPath:
          path: "/var/lib/glusterd"
      - name: glusterfs-dev
        hostPath:
          path: "/dev"
      - name: glusterfs-misc
        hostPath:
          path: "/var/lib/misc/glusterfsd"
EOF
		fi
		
	local TEMPLATE=/etc/kubernetes/manifests/heketi.yaml
    if [ ! -f "${TEMPLATE}" ]; then
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << EOF > $TEMPLATE
apiVersion: v1
kind: ServiceAccount
metadata:
  name: heketi-service-account
  namespace: filesystem
---
kind: Service
apiVersion: v1
metadata:
  name: deploy-heketi
  namespace: filesystem
  labels:
    glusterfs: heketi-service
    deploy-heketi: support
  annotations:
    description: Exposes Heketi Service
spec:
  selector:
    name: deploy-heketi
  ports:
  - name: deploy-heketi
    port: 8080
    targetPort: 8080
---
kind: Deployment
apiVersion: extensions/v1beta1
metadata:
  name: deploy-heketi
  namespace: filesystem
  labels:
    glusterfs: heketi-deployment
    deploy-heketi: heketi-deployment
  annotations:
    description: Defines how to deploy Heketi
spec:
  replicas: 1
  template:
    metadata:
      name: deploy-heketi
      labels:
        name: deploy-heketi
        glusterfs: heketi-pod
    spec:
      serviceAccountName: heketi-service-account
      containers:
      - image: quay.io/promaethius/heketi:master
        imagePullPolicy: Always
        name: deploy-heketi
        env:
        - name: HEKETI_EXECUTOR
          value: kubernetes
        - name: HEKETI_KUBE_USE_SECRET
          value: "y"
        - name: HEKETI_FSTAB
          value: "/var/lib/heketi/fstab"
        - name: HEKETI_SNAPSHOT_LIMIT
          value: '5'
        - name: HEKETI_KUBE_GLUSTER_DAEMONSET
          value: "y"
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: db
          mountPath: "/var/lib/heketi"
        readinessProbe:
          timeoutSeconds: 3
          initialDelaySeconds: 3
          httpGet:
            path: "/hello"
            port: 8080
        livenessProbe:
          timeoutSeconds: 3
          initialDelaySeconds: 30
          httpGet:
            path: "/hello"
            port: 8080
      volumes:
      - name: db
EOF
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
	docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/heapster-influx-graphana-de.yaml,/host/manifests/heapster-influx-graphana-svc.yaml
    echo "K8S: Kube-Lego addon"
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-lego.yaml
	echo "K8S: NGinx Ingress addon"
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/ingress-nginx.yaml,/host/manifests/default-backend.yaml
	echo "K8S: GlusterFS addon"
	docker run --rm --net=host -v /etc/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/glusterfs.yaml,/host/manifests/heketi.yaml
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
    # Deploy Calico
    #TODO: change to rkt once this is resolved (https://github.com/coreos/rkt/issues/3181)
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/calico-config.yaml,/host/manifests/calico.yaml

}

init_config
init_templates

chmod +x /opt/bin/host-rkt

init_flannel

#systemctl stop update-engine; systemctl mask update-engine

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
echo "DONE"
