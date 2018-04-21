#!/bin/bash

#
# Copyright 4eyes GmbH All Rights Reserved.
#
# Adaption from: https://github.com/hyperledger/fabric-samples/blob/release/first-network/byfn.sh
#

# This script will orchestrate end-to-end execution of the Hyperledger Fabric network.
#
# The end-to-end verification provisions a Fabric network consisting of
# on organization with maintaining two peers, and a “kafka” ordering service.
#
# This verification makes use of two fundamental tools, which are necessary to
# create a functioning transactional network with digital signature validation
# and access control:
#
# * cryptogen - generates the x509 certificates used to identify and
#   authenticate the various components in the network.
# * configtxgen - generates the requisite configuration artifacts for orderer
#   bootstrap and channel creation.
#
# Each tool consumes a configuration yaml file, within which we specify the topology
# of our network (cryptogen) and the location of our certificates for various
# configuration operations (configtxgen).  Once the tools have been successfully run,
# we are able to launch our network.  More detail on the tools and the structure of
# the network will be provided later in this document.  For now, let's get going...

# prepending $PWD/bin to PATH to ensure we are picking up the correct binaries
# this may be commented out to resolve installed version of tools if desired
export PATH=${PWD}/bin/bin:${PWD}:$PATH
export FABRIC_CFG_PATH=${PWD}

# set all variables in .env file as environmental variables
set -o allexport
source .env
set +o allexport

# Print the usage message
function printHelp () {
  echo "Usage: "
  echo "  ./fabric-network.sh -m download|up|down"
  echo "  ./fabric-network.sh -h|--help (print this message)"
  echo "    -m <mode> - one of 'up', 'start'"
  echo "      - 'download' - download fabric binaries and docker images"
  echo "      - 'up' - build the network: generate required certificates and genesis block & create all containers needed for the network"
  echo "      - 'down' - remove the network containers"

}

# Obtain CONTAINER_IDS and remove them
function clearContainers () {
  CONTAINER_IDS=$(docker ps -a | grep "dev\|hyperledger/fabric-\|test-vp\|peer[0-9]-" | awk '{print $1}')
  if [ -z "$CONTAINER_IDS" -o "$CONTAINER_IDS" == " " ]; then
    echo "---- No containers available for deletion ----"
  else
    docker rm -f $CONTAINER_IDS
  fi
}

# Delete any images that were generated as a part of this setup
# specifically the following images are often left behind:
function removeUnwantedImages() {
  DOCKER_IMAGE_IDS=$(docker images | grep "dev\|none\|test-vp\|peer[0-9]-" | awk '{print $3}')
  if [ -z "$DOCKER_IMAGE_IDS" -o "$DOCKER_IMAGE_IDS" == " " ]; then
    echo "---- No images available for deletion ----"
  else
    docker rmi -f $DOCKER_IMAGE_IDS
  fi
}

# download fabric binaries and docker images
function download() {
    export ARCH=$(echo "$(uname -s|tr '[:upper:]' '[:lower:]'|sed 's/mingw64_nt.*/windows/')-$(uname -m | sed 's/x86_64/amd64/g')" | awk '{print tolower($0)}')
    #Set MARCH variable i.e ppc64le,s390x,x86_64,i386
    MARCH=`uname -m`

    FABRIC_TAG="${MARCH}-${FABRIC_VERSION}"

    echo "download Hyperledger Fabric binaries"

    rm -rf bin
    mkdir bin
    echo "===> Downloading version ${FABRIC_TAG} platform specific fabric binaries"
    curl https://nexus.hyperledger.org/content/repositories/releases/org/hyperledger/fabric/hyperledger-fabric/${ARCH}-${FABRIC_VERSION}/hyperledger-fabric-${ARCH}-${FABRIC_VERSION}.tar.gz | tar xz -C bin

    echo "===> Downloading version ${FABRIC_TAG} platform specific fabric-ca-client binary"
    curl https://nexus.hyperledger.org/content/repositories/releases/org/hyperledger/fabric-ca/hyperledger-fabric-ca/${ARCH}-${FABRIC_VERSION}/hyperledger-fabric-ca-${ARCH}-${FABRIC_VERSION}.tar.gz | tar xz -C bin


    echo "===> Pulling fabric Images"

    for IMAGES in peer ccenv orderer ca; do
      echo "==> FABRIC IMAGE: $IMAGES"
      echo
      docker pull hyperledger/fabric-$IMAGES:$FABRIC_TAG
      docker tag hyperledger/fabric-$IMAGES:$FABRIC_TAG hyperledger/fabric-$IMAGES
    done

    echo
    echo "===> List out hyperledger docker images"
    docker images | grep hyperledger*
}

# Generate the needed certificates, the genesis block and start the network.
function networkUp () {
    generateCerts
    replacePrivateKey
    generateChannelArtifacts
    docker-compose up -d

    # wait for Hyperledger Fabric to start
    echo "sleeping for ${TIMEOUT} seconds to wait for fabric to complete start up"
    sleep $TIMEOUT

    # Create channel
    docker exec peer0.org1.${DOMAIN} peer channel create -o orderer.$DOMAIN:7050 -c $CHANNEL_NAME -f /opt/gopath/src/github.com/hyperledger/fabric/peer/$CHANNEL_FILE_NAME

    # Join peer0.org1 to the channel.
    docker exec peer0.org1.${DOMAIN} peer channel join -b $CHANNEL_NAME.block
}

# Tear down running network
function networkDown () {
    docker-compose down
    #Cleanup the chaincode containers
    clearContainers
    #Cleanup images
    removeUnwantedImages
    # remove orderer block and other channel configuration transactions and certs
    rm -rf $CHANNEL_ARTIFACTS_PATH crypto-config crypto-config.yaml configtx.yaml
    # remove the docker-compose yaml files that was customized
    rm -f $COMPOSE_CA_FILE
}

# Using docker-compose-ca-base-template.yaml, replace constants with private key file names
# generated by the cryptogen tool and output a docker-compose-ca-base.yaml specific to this
# configuration
function replacePrivateKey () {
  # sed on MacOSX does not support -i flag with a null extension. We will use
  # 't' for our back-up's extension and depete it at the end of the function
  ARCH=`uname -s | grep Darwin`
  if [ "$ARCH" == "Darwin" ]; then
    OPTS="-it"
  else
    OPTS="-i"
  fi

  # Copy the template to the file that will be modified to add the private key
  cp "$COMPOSE_CA_TEMPLATE" "$COMPOSE_CA_FILE"

  # The next steps will replace the template's contents with the
  # actual values of the private key file names for the two CAs.
  CURRENT_DIR=$PWD
  cd crypto-config/peerOrganizations/org1.$DOMAIN/ca/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/CA1_PRIVATE_KEY/${PRIV_KEY}/g" "$COMPOSE_CA_FILE"
  # If MacOSX, remove the temporary backup of the docker-compose file
  if [ "$ARCH" == "Darwin" ]; then
    rm "$COMPOSE_CA_BACKUP_FILE"
  fi
}

# We will use the cryptogen tool to generate the cryptographic material (x509 certs)
# for our various network entities.  The certificates are based on a standard PKI
# implementation where validation is achieved by reaching a common trust anchor.
#
# Cryptogen consumes a file - ``crypto-config.yaml`` - that contains the network
# topology and allows us to generate a library of certificates for both the
# Organizations and the components that belong to those Organizations.  Each
# Organization is provisioned a unique root certificate (``ca-cert``), that binds
# specific components (peers and orderers) to that Org.  Transactions and communications
# within Fabric are signed by an entity's private key (``keystore``), and then verified
# by means of a public key (``signcerts``).  You will notice a "count" variable within
# this file.  We use this to specify the number of peers per Organization; in our
# case it's two peers per Org.  The rest of this template is extremely
# self-explanatory.
#
# After we run the tool, the certs will be parked in a folder titled ``crypto-config``.

# Generates Org certs using cryptogen tool
function generateCerts (){
  which cryptogen
  if [ "$?" -ne 0 ]; then
    echo "cryptogen tool not found. exiting"
    exit 1
  fi
  echo
  echo "##########################################################"
  echo "##### Generate certificates using cryptogen tool #########"
  echo "##########################################################"
  if [ -d "crypto-config" ]; then
    rm -Rf crypto-config
  fi

  # sed on MacOSX does not support -i flag with a null extension. We will use
  # 't' for our back-up's extension and depete it at the end of the function
  ARCH=`uname -s | grep Darwin`
  if [ "$ARCH" == "Darwin" ]; then
    OPTS="-it"
  else
    OPTS="-i"
  fi

  CRYPTO_CONFIG_FILE="crypto-config.yaml"
  # Copy the template to the file that will be modified to add the domain name
  cp ./config-templates/crypto-config-template.yaml crypto-config.yaml

  # The next steps will replace the template's contents with the
  # actual values of the domain name.
  sed $OPTS "s/DOMAIN/${DOMAIN}/g" "${CRYPTO_CONFIG_FILE}"
  # If MacOSX, remove the temporary backup of the docker-compose file
  if [ "$ARCH" == "Darwin" ]; then
    rm "${CRYPTO_CONFIG_FILE}t"
  fi

  cryptogen generate --config=./${CRYPTO_CONFIG_FILE}
  if [ "$?" -ne 0 ]; then
    echo "Failed to generate certificates..."
    exit 1
  fi
  echo
}

# The `configtxgen tool is used to create four artifacts: orderer **bootstrap
# block**, fabric **channel configuration transaction**
#
# The orderer block is the genesis block for the ordering service, and the
# channel transaction file is broadcast to the orderer at channel creation
# time.
#
# Configtxgen consumes a file - ``configtx.yaml`` - that contains the definitions
# for the sample network. There are three members - one Orderer Org (``OrdererOrg``)
# and two Peer Orgs (``Org1``) each managing and maintaining two peer nodes.
# This file also specifies a consortium - ``SampleConsortium`` - consisting of our
# two Peer Orgs.  Pay specific attention to the "Profiles" section at the top of
# this file.  You will notice that we have two unique headers. One for the orderer genesis
# block - ``OneOrgOrdererGenesis`` - and one for our channel - ``OneOrgChannel``.
# These headers are important, as we will pass them in as arguments when we create
# our artifacts.  This file also contains two additional specifications that are worth
# noting.  Firstly, we specify the anchor peers for each Peer Org
# (``peer0.org1.$DOMAIN`` & ``peer0.org2.$DOMAIN``).  Secondly, we point to
# the location of the MSP directory for each member, in turn allowing us to store the
# root certificates for each Org in the orderer genesis block.  This is a critical
# concept. Now any network entity communicating with the ordering service can have
# its digital signature verified.
#
# This function will generate the crypto material and our four configuration
# artifacts, and subsequently output these files into the ``$CHANNEL_ARTIFACTS_PATH``
# folder.
#
# If you receive the following warning, it can be safely ignored:
#
# [bccsp] GetDefault -> WARN 001 Before using BCCSP, please call InitFactories(). Falling back to bootBCCSP.
#
# You can ignore the logs regarding intermediate certs, we are not using them in
# this crypto implementation.

# Generate orderer genesis block and channel configuration transaction
function generateChannelArtifacts() {
  which configtxgen
  if [ "$?" -ne 0 ]; then
    echo "configtxgen tool not found. exiting"
    exit 1
  fi

  echo "creating $CHANNEL_ARTIFACTS_PATH folder..."
  rm -rf ./$CHANNEL_ARTIFACTS_PATH
  mkdir ./$CHANNEL_ARTIFACTS_PATH

  # sed on MacOSX does not support -i flag with a null extension. We will use
  # 't' for our back-up's extension and depete it at the end of the function
  ARCH=`uname -s | grep Darwin`
  if [ "$ARCH" == "Darwin" ]; then
    OPTS="-it"
  else
    OPTS="-i"
  fi

  CONFIGTX_FILE="configtx.yaml"
  # Copy the template to the file that will be modified to add the domain name
  cp ./config-templates/configtx-template.yaml configtx.yaml

  # The next steps will replace the template's contents with the
  # actual values of the domain name.
  sed $OPTS "s/DOMAIN/${DOMAIN}/g" "${CONFIGTX_FILE}"

  echo "##########################################################"
  echo "#########  Generating Orderer Genesis block ##############"
  echo "##########################################################"
  # Note: For some unknown reason (at least for now) the block file can't be
  # named orderer.genesis.block or the orderer will fail to launch!
  configtxgen -profile OneOrgOrdererGenesis -outputBlock ./$CHANNEL_ARTIFACTS_PATH/$GENESIS_FILE_NAME
  if [ "$?" -ne 0 ]; then
    echo "Failed to generate orderer genesis block..."
    exit 1
  fi
  echo
  echo "#################################################################"
  echo "### Generating channel configuration transaction '$CHANNEL_FILE_NAME' ###"
  echo "#################################################################"
  configtxgen -profile OneOrgChannel -outputCreateChannelTx ./$CHANNEL_ARTIFACTS_PATH/$CHANNEL_FILE_NAME -channelID $CHANNEL_NAME
  if [ "$?" -ne 0 ]; then
    echo "Failed to generate channel configuration transaction..."
    exit 1
  fi

  # If MacOSX, remove the temporary backup of the docker-compose file
  if [ "$ARCH" == "Darwin" ]; then
    rm "${CONFIGTX_FILE}t"
  fi
}

# Obtain the OS and Architecture string that will be used to select the correct
# native binaries for your platform
OS_ARCH=$(echo "$(uname -s|tr '[:upper:]' '[:lower:]'|sed 's/mingw64_nt.*/windows/')-$(uname -m | sed 's/x86_64/amd64/g')" | awk '{print tolower($0)}')
# timeout duration - the duration the CLI should wait for a response from
# another container before giving up
CLI_TIMEOUT=10
#default for delay
CLI_DELAY=3
# use this file as the default docker-compose yaml definition
COMPOSE_FILE=docker-compose.yaml
# use this file to start cli container
CLI_COMPOSE_FILE=docker-compose-cli.yaml
#
COMPOSE_CA_TEMPLATE=docker-compose-base/docker-compose-ca-base-template.yaml
COMPOSE_CA_FILE=docker-compose-base/docker-compose-ca-base.yaml
COMPOSE_CA_BACKUP_FILE=docker-compose-base/docker-compose-ca-base.yamlt

# Parse commandline args
while getopts "h?m:" opt; do
  case "$opt" in
    h|\?)
      printHelp
      exit 0
    ;;
    m)  MODE=$OPTARG
    ;;
  esac
done

# Determine whether starting, stopping or generating for announce
if [ "$MODE" == "up" ]; then
  EXPMODE="Building"
  elif [ "$MODE" == "down" ]; then
  EXPMODE="Stopping"
  elif [ "$MODE" == "download" ]; then
  EXPMODE="download fabric binaries and docker images"
else
  printHelp
  exit 1
fi

# Announce what was requested
echo "${EXPMODE} with channel '${CHANNEL_NAME}'"


if [ "${MODE}" == "up" ]; then
  networkUp
  elif [ "${MODE}" == "down" ]; then
  networkDown
  elif [ "${MODE}" == "download" ]; then
  download
else
  printHelp
  exit 1
fi