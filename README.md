# 4eyes GmbH hyperledger fabric basic network

[See our blog.4eyes.ch blog-post on how to run this network](https://blog.4eyes.ch/minimal-fabric-development-environment/)

Note: these instructions are only for MACOS and Linux (Debian & Ubuntu)

## Prerequisites
- cURL
- Docker & Docker Compose
- git

## Configuration
You can modify several values in the .env file like the DOMAIN, TIME_ZONE, FABRIC_VERSION, etc ...

## Start for first time
clone this repo then:
- $ ./network.sh -m download
- $ ./network.sh -m up

## Start or stop the network (not for first time setup)
- $ ./network.sh -m start
- $ ./network.sh -m stop

### Recreate the containers without losing the data
- $ ./network.sh -m recreate

## Clean and Remove the network 
- $ ./network.sh -m down
