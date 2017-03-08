#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="../env.sh"
ENVSUBST_BIN=$(which envsubst)
TEMPLATE_DIR="templates"
FILES_DIR="files"
source ${DIR}/${ENV_FILE}

if [ -x "${ENVSUBST_BIN}" ]; then
        echo "found envsubst executable in ${ENVSUBST_BIN}"
else
        echo "could not find envsubst in PATH (part of gettext package)"
        exit
fi

for f in `find ${TEMPLATE_DIR} -type f`; do
        FILE=${f#${TEMPLATE_DIR}/}
        echo "parsing template file ${FILE}"
        ${ENVSUBST_BIN} < ${f} > ${FILE}
done

echo generating Kubernetes API Server Keypair....

openssl genrsa -out ca-key.pem 2048
openssl req -x509 -new -nodes -key ca-key.pem -days 10000 -out ca.pem -subj "/CN=kube-ca"

openssl genrsa -out apiserver-key.pem 2048
openssl req -new -key apiserver-key.pem -out apiserver.csr -subj "/CN=kube-apiserver" -config openssl.cnf
openssl x509 -req -in apiserver.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out apiserver.pem -days 365 -extensions v3_req -extfile openssl.cnf

echo generating Kubernetes Worker Keypairs...

cp ${FILES_DIR}/* .

openssl genrsa -out ${WORKER_FQDN}-worker-key.pem 2048
WORKER_IP=${WORKER_IP} openssl req -new -key ${WORKER_FQDN}-worker-key.pem -out ${WORKER_FQDN}-worker.csr -subj "/CN=${WORKER_FQDN}" -config worker-openssl.cnf
WORKER_IP=${WORKER_IP} openssl x509 -req -in ${WORKER_FQDN}-worker.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out ${WORKER_FQDN}-worker.pem -days 365 -extensions v3_req -extfile worker-openssl.cnf 

echo Generate the Cluster Administrator Keypair...
openssl genrsa -out admin-key.pem 2048
openssl req -new -key admin-key.pem -out admin.csr -subj "/CN=kube-admin"
openssl x509 -req -in admin.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out admin.pem -days 365

echo DONE
