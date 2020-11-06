#!/bin/bash

POOL_SIZE=8G
ROOT_DIR=/tmp/dfs_test
NAME_SIZE=8
DIR_DEEP=6
DIR_CHILDREN=3
NUMBER_OF_FILES=5
DIR_TEMPLATE=XXXXXXXX
FILE_TEMPLATE=XXXXXXXX.bin
NUM_OF_CONTAINERS=20
CONTAINER_NAMES=()


unset POOL_UUID

function print_header {
    echo
    printf '%80s\n' | tr ' ' =
    echo "          ${1}"
    printf '%80s\n' | tr ' ' =
    echo
}

function release_containers(){
    for i in "${CONTAINER_NAMES[@]}"
    do
        local TARGET_DIR=${ROOT_DIR}/${i}

        if [ -d ${TARGET_DIR} ] ; then
            fusermount3 -u ${TARGET_DIR}
        fi
    done
}

function teardown(){
    print_header "Running teardown"

    release_containers

    if [ ! -z ${POOL_UUID+x} ]; then
        dmg -i pool destroy --pool ${POOL_UUID} --force
    fi
}

function check_retcode(){
    exit_code=${1}
    last_command=${2}

    teardown
    echo "End Time: $(date)"

    if [ ${exit_code} -ne 0 ]; then
        print_header "Error report"
        echo "${last_command} command failed with exit code ${exit_code}."
        echo
        echo "STATUS: FAIL"
        exit ${exit_code}
    fi

    echo
    echo "STATUS: SUCCESS"
}
trap 'check_retcode $? ${BASH_COMMAND}' EXIT
set -e

function create_pool(){
    print_header "Creating pool"
    cmd="dmg -i pool create --scm-size ${POOL_SIZE}"
    echo ${cmd}
    echo
    DAOS_POOL=`${cmd}`
    POOL_UUID="$(grep -o "UUID: [A-Za-z0-9\-]*" <<< $DAOS_POOL | awk '{print $2}')"
    POOL_SVC="$(grep -o "Service replicas: [A-Za-z0-9\-]*" <<< $DAOS_POOL | awk '{print $3}')"
    echo
    echo "POOL_UUID: ${POOL_UUID}"
    echo "POOL_SVC : ${POOL_SVC}"
}

function _create_container(){
    print_header "Creating container"
    CONT_UUID=$(uuidgen)
    daos container create --pool ${POOL_UUID} --svc ${POOL_SVC} --cont ${CONT_UUID} --type POSIX
}

function get_random_string(){
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${NAME_SIZE} | head -n 1
}

function create_directories(){
    local CURRENT_DEEP=${1}
    local CURRENT_DIR=${2}

    # Create files
    for i in $(seq 1 ${NUMBER_OF_FILES})
    do
        mktemp -t ${FILE_TEMPLATE} --tmpdir=${CURRENT_DIR} &>/dev/null
    done 

    if [[ ${CURRENT_DEEP} -lt ${DIR_DEEP} ]] ; then
        for i in $(seq 1 ${DIR_CHILDREN})
        do
            # Create nested directories
            NEXT_DIR=$(mktemp -d -t ${DIR_TEMPLATE} --tmpdir=${CURRENT_DIR})
            create_directories $((CURRENT_DEEP + 1)) ${NEXT_DIR}
        done
    fi
}

function populate_directory(){
    local TARGET_DIR=${1}

    echo "Populating ${TARGET_DIR}..."
    create_directories 0 ${TARGET_DIR}

    echo "Created $(tree ${TARGET_DIR} | tail -n1) at ${TARGET_DIR}"
}

function create_containers(){
    print_header "Creating containers"

    for i in $(seq -f "%04g" 1 ${NUM_OF_CONTAINERS})
    do
        local CONTAINER_NAME=cont_${i}
        echo "Creating container ${CONTAINER_NAME}"
        CONTAINER_NAMES+=(${CONTAINER_NAME})

        local CONT_UUID=$(uuidgen)
        local TARGET_DIR=${ROOT_DIR}/${CONTAINER_NAME}

        daos container create --pool ${POOL_UUID} --svc ${POOL_SVC} \
                              --cont ${CONT_UUID} --type POSIX
        mkdir -p ${TARGET_DIR}
        dfuse --mountpoint ${TARGET_DIR} --pool ${POOL_UUID} \
              --svc ${POOL_SVC} --container ${CONT_UUID}
    done
}

function show_mounted_containers(){
    print_header "Posix containers"

    df -h | head -n1
    df -h | grep dfuse

    echo
    dmg -i pool query --pool ${POOL_UUID}
}

function populating_containers(){
    print_header "Populating containers"

    local PIDS=()

    for i in "${CONTAINER_NAMES[@]}"
    do
        populate_directory ${ROOT_DIR}/${i} &
        PIDS+=($!)
    done

    # wait for all the population routines
    for PID in "${PIDS[@]}"
    do
        wait ${PID}
    done

    echo
    echo "All files and directories were created on all the containers"
}

function create_needle(){
    local HAYSTACK=${1}

    for i in $(seq 1 ${DIR_DEEP})
    do
        HAYSTACK+=/$(get_random_string)
    done

    mkdir -p ${HAYSTACK}
    mktemp -t needle_${FILE_TEMPLATE} --tmpdir=${HAYSTACK}
}

function create_needles(){
    print_header "Creating needles"

    NEEDLES=()

    for i in "${CONTAINER_NAMES[@]}"
    do
        local NEEDLE=$(create_needle ${ROOT_DIR}/${i})
        NEEDLES+=(${NEEDLE})
        echo "${NEEDLE}"
    done
}

function search_needles(){
    print_header "Searching for needles at ${ROOT_DIR}"

    for i in "${NEEDLES[@]}"
    do
        local FILE_NAME=$(basename ${i})
        echo "Searching file: ${FILE_NAME}"
        RES=$(find ${ROOT_DIR} -name ${FILE_NAME})
        if [ "${RES}" = "${i}" ] ; then
            echo "  pass"
        else
            echo "  failed"
        fi
    done

    echo
    echo "Searching all needles at ${ROOT_DIR}"
    echo
    find ${ROOT_DIR} -name needle*.bin
    echo
    echo "Haystack (${ROOT_DIR}) has a total of $(tree ${ROOT_DIR} | tail -n1)"
}

echo "Testing find command on POSIX containers"
echo "Start Time: $(date)"

rm -rf ${ROOT_DIR}
mkdir -p ${ROOT_DIR}

create_pool
create_containers
show_mounted_containers
populating_containers
create_needles
search_needles
show_mounted_containers
