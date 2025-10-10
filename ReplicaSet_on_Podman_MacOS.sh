#!/bin/bash  
  
#-----------------------------------------------------------------------------  
# MongoDB Replica Set Setup Script for macOS with Podman  
#-----------------------------------------------------------------------------  
  
# ------------------ CONFIGURATION VARIABLES --------------------  
  
# MongoDB image (modify as required, default tagless)  
MONGODB_IMAGE="docker.io/mongodb/mongodb-enterprise-server"  
  
# Set to "yes" to add /etc/hosts records.   
# Set to "no" to skip /etc/hosts edit. No interactive prompt.  
MODIFY_HOSTS="yes"  
  
# ---------------------------------------------------------------  
  
# Quit on error  
set -e  
  
function ensure_podman_machine_running() {  
    if ! command -v podman > /dev/null; then  
        echo "Podman is not installed. Install Podman for Mac first."  
        exit 1  
    fi  
    if ! podman info > /dev/null 2>&1; then  
        echo "Podman machine is not running. Starting..."  
        podman machine start  
    else  
        echo "Podman machine is running."  
    fi  
}  
  
function ensure_mongodb_image_present() {  
    if podman image exists "$MONGODB_IMAGE"; then  
        echo "MongoDB image '$MONGODB_IMAGE' already exists."  
    else  
        echo "Pulling MongoDB image '$MONGODB_IMAGE' ..."  
        podman pull "$MONGODB_IMAGE"  
    fi  
}  
  
function ensure_data_directories() {  
    local BASED="$HOME/Desktop/mongo-data"  
    local DIRS=("rs0-0" "rs0-1" "rs0-2")  
    for d in "${DIRS[@]}"; do  
        [ -d "$BASED/$d" ] || mkdir -p "$BASED/$d"  
        echo "Ensured $BASED/$d exists."  
    done  
}  
  
function ensure_podman_network() {  
    if podman network exists mongo-rs; then  
        echo "Podman network 'mongo-rs' exists."  
    else  
        podman network create mongo-rs  
    fi  
}  

function ensure_mongo_containers() {  
    names=(mongo1 mongo2 mongo3)  
    ports=(27017 27018 27019)  
    datadirs=(rs0-0 rs0-1 rs0-2)  
    BASED="$HOME/Desktop/mongo-data"  
    for i in "${!names[@]}"; do  
        cname="${names[$i]}"  
        cport="${ports[$i]}"  
        cdir="${datadirs[$i]}"  
        if podman ps --format "{{.Names}}" | grep -wq "$cname"; then  
            echo "Container $cname running."  
        else  
            if podman ps -a --format "{{.Names}}" | grep -wq "$cname"; then  
                echo "Restarting existing container $cname ..."  
                podman start "$cname"  
            else  
                echo "Starting new container $cname ..."  
                podman run -d --name "$cname" --network mongo-rs -v "$BASED/$cdir:/data/db" -p "$cport:27017" "$MONGODB_IMAGE" --replSet rs0
            fi  
        fi  
    done  
}
  
# Attempt to add entries; skip if already present or if MODIFY_HOSTS=="no"  
function ensure_hosts_entry() {  
    HOSTS_TO_ADD=("127.0.0.1 mongo1" "127.0.0.1 mongo2" "127.0.0.1 mongo3")  
  
    if [ "$MODIFY_HOSTS" = "yes" ]; then  
        for H in "${HOSTS_TO_ADD[@]}"; do  
            if ! grep -q "$H" /etc/hosts; then  
                echo "$H" | sudo tee -a /etc/hosts >/dev/null  
                echo "Added $H to /etc/hosts"  
            fi  
        done  
    else  
        echo "Skipping host file modification by request."  
    fi  
}  
  
# Initiate the replica set via the first container and show status  
function initiate_replica_set() {  
    echo "Waiting for mongo1 to be up and accepting connections (db.adminCommand('ping'))..."  
    local tries=0  
    local maxtries=30  
    until podman exec mongo1 mongosh --quiet --eval "db.adminCommand('ping')" &>/dev/null  
    do  
        tries=$((tries+1))  
        if [ $tries -ge $maxtries ]; then  
            echo "MongoDB did not become ready for connections in time. Giving up."  
            exit 2  
        fi  
        sleep 2  
    done  
    echo "mongo1 is accepting connections, will attempt to initiate the replica set."  
  
    # Try to initiate the replica set. Retry if necessary.  
    tries=0  
    maxtries=10  
    while true; do  
        podman exec mongo1 mongosh --quiet --eval "  
            rs.initiate({  
              _id: 'rs0',  
              members: [  
                { _id: 0, host: 'mongo1:27017', priority: 2 },  
                { _id: 1, host: 'mongo2:27017', priority: 1 },  
                { _id: 2, host: 'mongo3:27017', priority: 1 }  
              ]  
            })  
        " 2>&1 | tee /tmp/mongo-init-rs.log  
  
        # Now check if replica set is healthy  
        podman exec mongo1 mongosh --quiet --eval '  
            try {  
                let s = rs.status();  
            //    printjson(s);    //uncomment if you need to print rs.status() output in terminal
                if (s.ok && s.members && s.members.filter(m => m.stateStr=="PRIMARY" || m.stateStr=="SECONDARY").length == 3) {  
                  print("Replica set health check successful!");  
                  quit(0);  
                }  
            } catch (e) {}  
            quit(1);  
        ' && { echo "Replica set initiated and healthy!"; break; }  
  
        tries=$((tries+1))  
        if [ $tries -ge $maxtries ]; then  
            echo "Could not initiate replica set after several attempts. Please check containers manually."  
            exit 3  
        fi  
        sleep 3  
        echo "Replica set not ready yet, retrying initiation (attempt $((tries+1))/$maxtries)..."  
    done  
}  
  
# -------------------- MAIN --------------------  
  
ensure_podman_machine_running  
ensure_mongodb_image_present  
ensure_data_directories  
ensure_podman_network  
ensure_mongo_containers  
  
initiate_replica_set  
ensure_hosts_entry  
  
echo "  
==============================================================================  
MongoDB Enterprise Replica Set is up.  
  
Connection String for Compass:
    mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0  

Try mongosh:
    mongosh "mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0"
  
If you did NOT modify /etc/hosts, use:
    podman exec -it mongo1 mongosh \"mongodb://mongo1:27017,mongo2:27017,mongo3:27017/?replicaSet=rs0\"  
==============================================================================  
  
"  
  
exit 0
