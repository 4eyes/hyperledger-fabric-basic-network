# 4eyes GmbH hyperledger fabric basic network

Note: these instructions are only for MACOS and Linux (Debian & Ubuntu)

## Prerequisites
- cURL
- Docker & Docker Compose
- git

## Configuration
You can modify several values in the .env file like the DOMAIN, TIME_ZONE, FABRIC_VERSION, etc ...

## Start for first time
clone this repo then:
- $ cd hyperledger-fabric-basic-network
- $ ./network.sh -m download
- $ ./network.sh -m up

## Start or stop the netwotk (not for first time setup)
- $ cd hyperledger-fabric-basic-network
- $ docker-compose start
- $ docker-compose stop

## Clean and Remove the network 
- $ cd hyperledger-fabric-basic-network
- $ ./network.sh -m down
