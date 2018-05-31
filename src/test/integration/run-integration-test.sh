#!/bin/bash
#
# Copyright (c) 2018 Dell Inc., or its subsidiaries. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
 
# Download and install flink
set -veu
FLINK_VERSION=${FLINK_VERSION:-1.4.2}
FLINK_PORTAL_PORT=${FLINK_PORTAL_PORT:-8081}
PRAVEGA_REST_PORT=${PRAVEGA_REST_PORT:-9091}
PRAVEGA_CONTROLLER_PORT=${PRAVEGA_CONTROLLER_PORT:-9090}
SCALA_VERSION=${SCALA_VERSION:-2.11}
WAIT_RETRIES=${WAIT_RETRIES:-48}
WAIT_SLEEP=${WAIT_SLEEP:-5}
HTTP_OK=200

ROOT_DIR=$PWD

wait_for_service() {
    url=$1
    count=0
    set -x
    until [ "$(curl -s -o /dev/null -w ''%{http_code}'' $url)" = "$HTTP_OK" ]; do
        if [ $count -ge ${WAIT_RETRIES} ]; then
            exit 1;
        fi
        count=$(($count+1))
        sleep ${WAIT_SLEEP}
    done
    set +x
}

# Download flink
FLINK_DIR=${ROOT_DIR}/flink-${FLINK_VERSION}
FLINK_BINARY=flink-${FLINK_VERSION}-bin-hadoop28-scala_${SCALA_VERSION}.tgz
wget --no-check-certificate https://archive.apache.org/dist/flink/flink-${FLINK_VERSION}/${FLINK_BINARY}
tar zxvf $FLINK_BINARY

# Increase job slots, then start flink cluster
sed -i '/taskmanager.numberOfTaskSlots/c\taskmanager.numberOfTaskSlots: 5' ${FLINK_DIR}/conf/flink-conf.yaml
${FLINK_DIR}/bin/start-cluster.sh 

# wait for Flink cluster to start
wait_for_service http://localhost:${FLINK_PORTAL_PORT}

# Download and install Pravega
# For the time being, use the Pravega submodule in Flink connector.
# Eventually use a stable Pravega build that is compatible with Flink connector
cd ${ROOT_DIR}/pravega
#./gradlew startstandalone 2>&1 | tee /tmp/pravega.log &
./gradlew startstandalone > /dev/null 2>&1 &

# wait for Pravega to start
wait_for_service http://localhost:${PRAVEGA_REST_PORT}/v1/scopes

# Compile and run sample Flink application
cd ${ROOT_DIR}
git clone https://github.com//pravega/pravega-samples
cd ${ROOT_DIR}/pravega-samples
git checkout develop
./gradlew :flink-examples:installDist

rm -f ${FLINK_DIR}/log/* 

# start ExactlyOnceWriter
${FLINK_DIR}/bin/flink run -c io.pravega.examples.flink.primer.process.ExactlyOnceWriter flink-examples/build/install/pravega-flink-examples/lib/pravega-flink-examples-0.3.0-SNAPSHOT-all.jar --controller tcp://localhost:${PRAVEGA_CONTROLLER_PORT} --scope myscope --stream mystream --exactlyonce true

# start ExactlyOnceChecker
${FLINK_DIR}/bin/flink run -c io.pravega.examples.flink.primer.process.ExactlyOnceChecker flink-examples/build/install/pravega-flink-examples/lib/pravega-flink-examples-0.3.0-SNAPSHOT-all.jar --controller tcp://localhost:${PRAVEGA_CONTROLLER_PORT} --scope myscope --stream mystream &

job_id=$((${FLINK_DIR}/bin/flink list)  | grep ExactlyOnce | awk '{print $4}')
count=0
set -x
until grep -q "EXACTLY_ONCE" ${FLINK_DIR}/log/*taskmanager*.out; do
    if [ $count -ge 24 ]; then
        ${FLINK_DIR}/bin/flink cancel $job_id
        exit 1
    fi
    count=$(($count+1))
    sleep ${WAIT_SLEEP}
done
${FLINK_DIR}/bin/flink stop $job_id
