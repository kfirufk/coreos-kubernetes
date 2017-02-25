# Kubernetes on CoreOS with Generic Install Scripts

## fork of [Promaethius's coreos-kubernetes](https://github.com/Promaethius/coreos-kubernetes) fork :)

### thanks

Promaethius created a wonderful fork that fixes many issues including 
using calico with rkt. (it uses docker where relevant till rkt bugfixes will be resolved)

### why
the controller install script is a hugh bash script that creates
all the relevant files. I wanted to have this script in a format that is easy
to maintain.

### WORK IN PROGRESS

- [DONE] create `server-files` directory and place relevant files needed for controller installation
- [DONE] create `templates` directory and place relevant template files
- [DONE] create `env.sh` environment file to be used when parsing template files
- [DONE] create `compile-server-files.sh` bash script that will prepare all relevant server files
- copy content of `server-files` and `templates` direcory to their appropriate locations
- [NOT COMPLETE] create `create install-kube.sh` bash script to configure and start kubernetes
- create a main `controller-install.sh` bash script to load all other bash scripts and install everything
- create a `kubernetes-test.sh` bash script to test succesfull installation of kubernetes

# contact me
for any questions, comments, or... just anything,
feel free to email me at kfirufk@gmail.com