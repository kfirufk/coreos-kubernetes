* replace static data in controller-install/templates/etc/kubernetes/controller-kubeconfig.yaml
* replace static data in worker-install/templates/etc/kubernetes/worker-kubeconfig.yaml
* replace static data in controller-install/templates/srv/kubernetes/manifests/calico.yaml
* create /var/run/calico on kubelet.service (both controller and worker) only if calico is enabled
* complete uninstall-kube script
