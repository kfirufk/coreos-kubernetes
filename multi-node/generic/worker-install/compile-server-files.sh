#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SERVER_FILES_DIR="server-files"
TEMPLATE_DIR="templates"
ENVSUBST_BIN=$(which envsubst)
YES_BIN=$(which yes)
ENV_FILE="env.sh"
YES_COMMAND="yes"
OVERWRITE_WITH_CONFIRMATION_PROMPT=false

if [ ! -f "${DIR}/${ENV_FILE}" ]; then
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

if [ -x "${YES_BIN}" ]; then
    echo "found yes executable in ${YES_BIN}"
else
    echo "could not find yes in PATH"
    exit
fi

if [ -x "${ENVSUBST_BIN}" ]; then
	echo "found envsubst executable in ${ENVSUBST_BIN}"
else
	echo "could not find envsubst in PATH (part of gettext package)"
	exit
fi	
	
source ${DIR}/${ENV_FILE}

for d in `find ${TEMPLATE_DIR} -type d`; do
	T_DIR=${d#${TEMPLATE_DIR}/}
	if mkdir -p ${1}/${T_DIR}; then
		echo "creating directory ${1}/${T_DIR}"
	else
		echo "failed creating directory ${1}/${T_DIR}"
		exit
	fi	
done       	

for f in `find ${TEMPLATE_DIR} -type f`; do 
	FILE=${f#${TEMPLATE_DIR}/}
	echo "parsing template file ${FILE}"
	${ENVSUBST_BIN} < ${f} > ${1}/${FILE}
done

echo "done compiling template"

if [ "$OVERWRITE_WITH_CONFIRMATION_PROMPT" = true ]; then
    echo "copying files with overwrite confirmation prompt..."
    echo "from {DIR}/${SERVER_FILES_DIR}"
    cp -Riv ${DIR}/${SERVER_FILES_DIR}/* ${DIR}/${1}
    echo "from ${DIR}/${1}"
    cp -Riv ${DIR}/${1}/* /
else
    echo "copying files and overwriting any previous files..."
    echo "from {DIR}/${SERVER_FILES_DIR}"
    ${YES_BIN} | cp -Rv ${DIR}/${SERVER_FILES_DIR}/* ${DIR}/${1}
    echo "from ${DIR}/${1}"
    ${YES_BIN} | cp -Rv ${DIR}/${1}/* /
fi

echo "DONE! time to install kubernetes!"

