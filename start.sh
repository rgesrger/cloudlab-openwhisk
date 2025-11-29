#!/bin/bash
set -x

BASE_IP="10.10.1."
SECONDARY_PORT=3000
INSTALL_DIR=/home/cloudlab-openwhisk
NUM_MIN_ARGS=3
PRIMARY_ARG="primary"
SECONDARY_ARG="secondary"
USAGE=$'Usage:\n\t./start.sh secondary <node_ip> <start_kubernetes>\n\t./start.sh primary <node_ip> <num_nodes> <start_kubernetes> <deploy_openwhisk> <invoker_count> <invoker_engine> <scheduler_enabled>'
NUM_PRIMARY_ARGS=8
PROFILE_GROUP="profileuser"

# --- Helper to prevent apt-get lock issues ---
wait_for_apt_lock() {
    while sudo fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock >/dev/null 2>&1; do
        echo "Waiting for apt lock..."
        sleep 5
    done
}

configure_docker_storage() {
    printf "%s: %s\n" "$(date +"%T.%N")" "Configuring docker storage"
    sudo mkdir -p /mydata/docker
    echo -e '{
        "exec-opts": ["native.cgroupdriver=systemd"],
        "log-driver": "json-file",
        "log-opts": {
            "max-size": "100m"
        },
        "storage-driver": "overlay2",
        "data-root": "/mydata/docker"
    }' | sudo tee /etc/docker/daemon.json

    sudo systemctl restart docker || (echo "ERROR: Docker installation failed, exiting." && exit -1)
    
    # Wait for Docker socket
    while [ ! -S /var/run/docker.sock ]; do sleep 1; done

    sudo docker run hello-world | grep "Hello from Docker!" || (echo "ERROR: Docker installation failed, exiting." && exit -1)
    printf "%s: %s\n" "$(date +"%T.%N")" "Configured docker storage to use mountpoint"
}

disable_swap() {
    sudo swapoff -a
    if [ $? -eq 0 ]; then   
        printf "%s: %s\n" "$(date +"%T.%N")" "Turned off swap"
    else
        echo "***Error: Failed to turn off swap, which is necessary for Kubernetes"
        exit -1
    fi
    sudo sed -i.bak 's/UUID=.*swap/# &/' /etc/fstab
}

setup_secondary() {
    SECONDARY_IP="$1"

    # Wait for the IP to exist
    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for IP $SECONDARY_IP..."
    while ! ip addr | grep -q "$SECONDARY_IP"; do sleep 1; done
    printf "%s: %s\n" "$(date +"%T.%N")" "IP $SECONDARY_IP ready!"

    # Wait for Docker
    while [ ! -S /var/run/docker.sock ]; do sleep 1; done

    # Start netcat listener
    while true; do
        printf "%s: %s\n" "$(date +"%T.%N")" "Starting listener on port $SECONDARY_PORT..."
        # Listen on all interfaces to avoid "Cannot assign requested address"
        cmd=$(nc -l -p $SECONDARY_PORT)
        if [ -n "$cmd" ]; then
            printf "%s: %s\n" "$(date +"%T.%N")" "Received command: $cmd"
            eval "sudo $cmd"
            break
        else
            printf "%s: %s\n" "$(date +"%T.%N")" "Listener failed, retrying..."
        fi
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Secondary node joined Kubernetes!"
}

setup_primary() {
    PRIMARY_IP="$1"

    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for Docker socket..."
    while [ ! -S /var/run/docker.sock ]; do sleep 1; done

    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for IP $PRIMARY_IP to exist..."
    while ! ip addr | grep -q "$PRIMARY_IP"; do sleep 1; done

    sudo kubeadm init --apiserver-advertise-address=$PRIMARY_IP --pod-network-cidr=10.11.0.0/16 > $INSTALL_DIR/k8s_install.log 2>&1
    if [ $? -ne 0 ]; then
        echo "***Error: kubeadm init failed. Check $INSTALL_DIR/k8s_install.log"
        exit 1
    fi

    for FILE in /users/*; do
        CURRENT_USER=${FILE##*/}
        sudo mkdir -p /users/$CURRENT_USER/.kube
        sudo cp /etc/kubernetes/admin.conf /users/$CURRENT_USER/.kube/config
        sudo chown -R $CURRENT_USER:$PROFILE_GROUP /users/$CURRENT_USER/.kube
    done
}

apply_calico() {
    helm repo add projectcalico https://projectcalico.docs.tigera.io/charts > $INSTALL_DIR/calico_install.log 2>&1
    helm install calico projectcalico/tigera-operator --version v3.22.0 >> $INSTALL_DIR/calico_install.log 2>&1
    printf "%s: %s\n" "$(date +"%T.%N")" "Applied Calico networking"
}

add_cluster_nodes() {
    NUM_NODES="$1"
    REMOTE_CMD=$(tail -n 2 $INSTALL_DIR/k8s_install.log)
    for (( i=2; i<=NUM_NODES; i++ )); do
        SECONDARY_IP=$BASE_IP$i
        printf "%s: %s\n" "$(date +"%T.%N")" "Sending join command to $SECONDARY_IP..."
        while ! nc -z $SECONDARY_IP $SECONDARY_PORT; do sleep 1; done
        echo "$REMOTE_CMD" | nc $SECONDARY_IP $SECONDARY_PORT
    done
}

# --- Argument parsing ---
if [ $# -lt $NUM_MIN_ARGS ]; then
    echo "$USAGE"
    exit -1
fi

disable_swap
if test -d "/mydata"; then configure_docker_storage; fi
wait_for_apt_lock
sudo groupadd -f $PROFILE_GROUP
for FILE in /users/*; do
    CURRENT_USER=${FILE##*/}
    sudo gpasswd -a $CURRENT_USER $PROFILE_GROUP
    sudo gpasswd -a $CURRENT_USER docker
done

if [ $1 == $SECONDARY_ARG ]; then
    if [ "$3" == "False" ]; then exit 0; fi
    setup_secondary $2
    exit 0
fi

# Primary node path
if [ $# -ne $NUM_PRIMARY_ARGS ]; then
    echo "$USAGE"
    exit -1
fi

if [ "$4" = "False" ]; then exit 0; fi

setup_primary $2
apply_calico
add_cluster_nodes $3

printf "%s: %s\n" "$(date +"%T.%N")" "Cluster setup completed!"
