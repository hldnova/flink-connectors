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
ROOT_DIR=$PWD
FLINK_VERSION=1.4.2
SCALA_VERSION=2.11

RETRIES=48
SLEEP=5
HTTP_OK=200
wait_for_service() {
    url=$1
    count=0
    set -x
    until [ "$(curl -s -o /dev/null -w ''%{http_code}'' $url)" = "$HTTP_OK" ]; do
        if [ $count -ge $RETRIES ]; then
            exit 1;
        fi
        count=$(($count+1))
        sleep $SLEEP
    done
    set +x
}

FLINK_DIR=flink-${FLINK_VERSION}
FLINK_BINARY=flink-${FLINK_VERSION}-bin-hadoop28-scala_${SCALA_VERSION}.tgz
wget --no-check-certificate https://archive.apache.org/dist/flink/flink-1.4.2/${FLINK_BINARY}
tar zxvf $FLINK_BINARY
./${FLINK_DIR}/bin/start-cluster.sh 

# wait for Flink cluster to start
wait_for_service http://localhost:8081

# Download and install Pravega
# For the time being, use the Pravega submodule in Flink connector.
# Eventually use a stable Pravega build that is compatible with Flink connector
cd ${ROOT_DIR}/pravega
./gradlew startstandalone 2>&1 | tee /tmp/pravega.log &

# wait for Pravega to start
wait_for_service http://localhost:9091/v1/scopes

# Compile and run sample Flink application
cd ${ROOT_DIR}
git clone https://github.com//pravega/pravega-samples
cd ${ROOT_DIR}/pravega-samples
git checkout flink-issue-72-take2
./gradlew :flink-examples:installDist

${ROOT_DIR}/${FLINK_DIR}/bin/flink run -c io.pravega.examples.flink.primer.process.ExactlyOnceWriter flink-examples/build/install/pravega-flink-examples/lib/pravega-flink-examples-0.3.0-SNAPSHOT-all.jar --controler tcp://localhost:9090 --scope myscope --stream mystream --exactlyonce true
