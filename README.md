# 4eyes GmbH hyperledger fabric basic network

## Prerequisites
- cURL
- Docker & Docker Compose
- git

## Start for first time
clone this repo then:
- $ cd hyperledger-fabric-basic-network
- $ ./network -m download
- $ ./network -m up


## Start or stop the netwotk (not for first time setup)
- $ cd hyperledger-fabric-basic-network
- $ docker-compose start
- $ docker-compose stop


## Clean and Remove the network 
- $ cd hyperledger-fabric-basic-network
- $ ./network -m down