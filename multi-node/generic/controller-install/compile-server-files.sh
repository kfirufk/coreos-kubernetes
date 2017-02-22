#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SERVER_FILES_DIR="server-files"
TEMPLATE_DIR="templates"
ENVSUBST_BIN=$(which envsubst)
ENV_FILE="env.sh"
if [ ! -f ${DIR}/${ENV_FILE} ]; then
	echo "could not find ${ENV_FILE} in ${DIR}"
	exit
fi

if [ "$#" -ne 1 ]; then
    echo "Illegal number of parameters"
    echo "usage: ${0} <new_directory>"
    exit
fi

if [  -d ${1} ]; then
    echo "directory ${1} already exists"
    exit
fi


if [ -x "${ENVSUBST_BIN}" ]; then
	echo "found envsubst executable in ${ENVSUBST_BIN}"
else
	echo "could not find envsubst in PATH (part of gettext package)"
	exit
fi	
	

if cp -r ${DIR}/${SERVER_FILES_DIR} ${DIR}/${1}; then
    echo "succesfully copied server files into into ${DIR}/${1}"
else
    echo "could not copy server files directory into ${DIR}/${1}"
    exit
fi


source ${DIR}/${ENV_FILE}

for d in `find ${TEMPLATE_DIR} -type d`; do
	DIR=${d#${TEMPLATE_DIR}/}
	if mkdir -p ${1}/${DIR}; then
		echo "creating directory ${1}/${DIR}"
	else
		echo "failed creating directory ${1}/${DIR}"
		exit
	fi	
done       	

for f in `find ${TEMPLATE_DIR} -type f`; do 
	FILE=${f#${TEMPLATE_DIR}/}
	echo "parsing template file ${FILE}"
	${ENVSUBST_BIN} < ${f} > ${1}/${FILE}
	
done	

echo "done compliling template"
