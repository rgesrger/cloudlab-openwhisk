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

# ### FIX: Helper to prevent apt-get locking errors
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
    
    # ### FIX: Wait for socket to be actually ready
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

    # Wait for the IP to appear on the interface
    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for IP $SECONDARY_IP to be assigned..."
    while ! ip addr | grep -q "$SECONDARY_IP"; do
        sleep 1
        printf "."
    done
    printf "\n%s: %s\n" "$(date +"%T.%N")" "IP $SECONDARY_IP assigned!"

    # Ensure Docker socket is ready
    while [ ! -S /var/run/docker.sock ]; do sleep 1; done

    # Start netcat listener on all interfaces to avoid binding issues
    start_nc_listener() {
        coproc nc { nc -l $SECONDARY_PORT; }
        NC_PID=$!
    }

    start_nc_listener

    while true; do
        printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for command to join kubernetes cluster, nc pid is $NC_PID"
        if read -r -u${nc[0]} cmd; then
            case $cmd in
                *"kube"*)
                    MY_CMD=$cmd
                    break
                    ;;
                *)
                    printf "%s: %s\n" "$(date +"%T.%N")" "Read: $cmd"
                    ;;
            esac
        else
            printf "%s: %s\n" "$(date +"%T.%N")" "Netcat exited, restarting listener..."
            start_nc_listener
        fi
    done

    # Execute the join command
    MY_CMD=$(echo sudo $MY_CMD | sed 's/\\//')
    printf "%s: %s\n" "$(date +"%T.%N")" "Command to execute is: $MY_CMD"
    eval $MY_CMD

    printf "%s: %s\n" "$(date +"%T.%N")" "Done!"
}


setup_primary() {
    # ### FIX: Ensure Docker socket is ready before asking Kubeadm to use it
    echo "Waiting for Docker socket..."
    while [ ! -S /var/run/docker.sock ]; do sleep 1; done

    # initialize k8 primary node
    printf "%s: %s\n" "$(date +"%T.%N")" "Starting Kubernetes... (this can take several minutes)... "
    
    # ### FIX: Ensure the IP we are advertising actually exists on the interface
    # CloudLab DHCP can be slow. If we bind before the IP is assigned, Kubeadm crashes.
    echo "Waiting for IP $1 to be assigned to interface..."
    while ! ip addr | grep -q "$1"; do
        sleep 1
        echo -n "."
    done
    
    sudo kubeadm init --apiserver-advertise-address=$1 --pod-network-cidr=10.11.0.0/16 > $INSTALL_DIR/k8s_install.log 2>&1
    if [ $? -eq 0 ]; then
        printf "%s: %s\n" "$(date +"%T.%N")" "Done! Output in $INSTALL_DIR/k8s_install.log"
    else
        echo ""
        echo "***Error: Error when running kubeadm init command. Check log found in $INSTALL_DIR/k8s_install.log."
        exit 1
    fi

    # Set up kubectl for all users
    for FILE in /users/*; do
        CURRENT_USER=${FILE##*/}
        sudo mkdir -p /users/$CURRENT_USER/.kube
        sudo cp /etc/kubernetes/admin.conf /users/$CURRENT_USER/.kube/config
        sudo chown -R $CURRENT_USER:$PROFILE_GROUP /users/$CURRENT_USER/.kube
    printf "%s: %s\n" "$(date +"%T.%N")" "set /users/$CURRENT_USER/.kube to $CURRENT_USER:$PROFILE_GROUP!"
    ls -lah /users/$CURRENT_USER/.kube
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Done!"
}

apply_calico() {
    helm repo add projectcalico https://projectcalico.docs.tigera.io/charts > $INSTALL_DIR/calico_install.log 2>&1 
    if [ $? -ne 0 ]; then
       echo "***Error: Error when loading helm calico repo. Log written to $INSTALL_DIR/calico_install.log"
       exit 1
    fi
    printf "%s: %s\n" "$(date +"%T.%N")" "Loaded helm calico repo"

    helm install calico projectcalico/tigera-operator --version v3.22.0 >> $INSTALL_DIR/calico_install.log 2>&1
    if [ $? -ne 0 ]; then
       echo "***Error: Error when installing calico with helm. Log appended to $INSTALL_DIR/calico_install.log"
       exit 1
    fi
    printf "%s: %s\n" "$(date +"%T.%N")" "Applied Calico networking with helm"

    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for calico pods to have status of 'Running': "
    NUM_PODS=$(kubectl get pods -n calico-system | wc -l)
    NUM_RUNNING=$(kubectl get pods -n calico-system | grep " Running" | wc -l)
    NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    while [ "$NUM_RUNNING" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_RUNNING=$(kubectl get pods -n calico-system | grep " Running" | wc -l)
        NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Calico pods running!"
    
    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for all system pods to have status of 'Running': "
    NUM_PODS=$(kubectl get pods -n kube-system | wc -l)
    NUM_RUNNING=$(kubectl get pods -n kube-system | grep " Running" | wc -l)
    NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    while [ "$NUM_RUNNING" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_RUNNING=$(kubectl get pods -n kube-system | grep " Running" | wc -l)
        NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Kubernetes system pods running!"
}

add_cluster_nodes() {
    REMOTE_CMD=$(tail -n 2 $INSTALL_DIR/k8s_install.log)
    printf "%s: %s\n" "$(date +"%T.%N")" "Remote command is: $REMOTE_CMD"

    NUM_REGISTERED=$(kubectl get nodes | wc -l)
    NUM_REGISTERED=$(($1-NUM_REGISTERED+1))
    counter=0
    while [ "$NUM_REGISTERED" -ne 0 ]
    do 
        sleep 2
        printf "%s: %s\n" "$(date +"%T.%N")" "Registering nodes, attempt #$counter, registered=$NUM_REGISTERED"
        for (( i=2; i<=$1; i++ ))
        do
            SECONDARY_IP=$BASE_IP$i
            echo "Checking if $SECONDARY_IP:3000 is listening..."
            
            # Wait for secondary to start listening
            while ! nc -z $SECONDARY_IP $SECONDARY_PORT; do
                sleep 1
            done

            # Then send the join command
            exec 3<>/dev/tcp/$SECONDARY_IP/$SECONDARY_PORT
            echo $REMOTE_CMD 1>&3
            exec 3<&-
        done
        counter=$((counter+1))
        NUM_REGISTERED=$(kubectl get nodes | wc -l)
        NUM_REGISTERED=$(($1-NUM_REGISTERED+1)) 
    done

    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for all nodes to have status of 'Ready': "
    NUM_READY=$(kubectl get nodes | grep " Ready" | wc -l)
    NUM_READY=$(($1-NUM_READY))
    while [ "$NUM_READY" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_READY=$(kubectl get nodes | grep " Ready" | wc -l)
        NUM_READY=$(($1-NUM_READY))
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Done!"
}


prepare_for_openwhisk() {
    pushd $INSTALL_DIR/openwhisk-deploy-kube
    git pull
    popd

    NODE_NAMES=$(kubectl get nodes -o name)
    CORE_NODES=$(($2-$3))
    counter=0
    while IFS= read -r line; do
    if [ $counter -lt $CORE_NODES ] ; then
        printf "%s: %s\n" "$(date +"%T.%N")" "Skipped labelling non-invoker node ${line:5}"
        else
            kubectl label nodes ${line:5} openwhisk-role=invoker
            if [ $? -ne 0 ]; then
                echo "***Error: Failed to set openwhisk role to invoker on ${line:5}."
                exit -1
            fi
        printf "%s: %s\n" "$(date +"%T.%N")" "Labelled ${line:5} as openwhisk invoker node"
    fi
    counter=$((counter+1))
    done <<< "$NODE_NAMES"
    printf "%s: %s\n" "$(date +"%T.%N")" "Finished labelling nodes."

    kubectl create namespace openwhisk
    if [ $? -ne 0 ]; then
        echo "***Error: Failed to create openwhisk namespace"
        exit 1
    fi
    printf "%s: %s\n" "$(date +"%T.%N")" "Created openwhisk namespace in Kubernetes."

    # ### FIX: Wait for the repo file to be available (Race condition with NFS mount)
    echo "Waiting for mycluster.yaml to be available..."
    while [ ! -f /local/repository/mycluster.yaml ]; do
        sleep 1
        echo -n "."
    done

    cp /local/repository/mycluster.yaml $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sed -i.bak "s/REPLACE_ME_WITH_IP/$1/g" $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sed -i.bak "s/REPLACE_ME_WITH_INVOKER_ENGINE/$4/g" $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sed -i.bak "s/REPLACE_ME_WITH_INVOKER_COUNT/$3/g" $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sed -i.bak "s/REPLACE_ME_WITH_SCHEDULER_ENABLED/$5/g" $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sudo chown $USER:$PROFILE_GROUP $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sudo chmod -R g+rw $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    
    if [ $4 == "docker" ] ; then
        if test -d "/mydata"; then
        sed -i.bak "s/\/var\/lib\/docker\/containers/\/mydata\/docker\/containers/g" $INSTALL_DIR/openwhisk-deploy-kube/helm/openwhisk/templates/_invoker-helpers.tpl
            printf "%s: %s\n" "$(date +"%T.%N")" "Updated dockerrootdir to /mydata/docker/containers in $INSTALL_DIR/openwhisk-deploy-kube/helm/openwhisk/templates/_invoker-helpers.tpl"
        fi
    fi
}

deploy_openwhisk() {
    printf "%s: %s\n" "$(date +"%T.%N")" "About to deploy OpenWhisk via Helm... "
    cd $INSTALL_DIR/openwhisk-deploy-kube
    helm install owdev ./helm/openwhisk -n openwhisk -f mycluster.yaml > $INSTALL_DIR/ow_install.log 2>&1 
    if [ $? -eq 0 ]; then
        printf "%s: %s\n" "$(date +"%T.%N")" "Ran helm command to deploy OpenWhisk"
    else
        echo ""
        echo "***Error: Helm install error. Please check $INSTALL_DIR/ow_install.log."
        exit 1
    fi
    cd $INSTALL_DIR

    kubectl get pods -n openwhisk
    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for OpenWhisk to complete deploying (this can take several minutes): "
    DEPLOY_COMPLETE=$(kubectl get pods -n openwhisk | grep owdev-install-packages | grep Completed | wc -l)
    while [ "$DEPLOY_COMPLETE" -ne 1 ]
    do
        sleep 2
        DEPLOY_COMPLETE=$(kubectl get pods -n openwhisk | grep owdev-install-packages | grep Completed | wc -l)
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "OpenWhisk deployed!"
    
    for FILE in /users/*; do
        CURRENT_USER=${FILE##*/}
        echo -e "
    APIHOST=$1:31001
    AUTH=23bc46b1-71f6-4ed5-8c54-816aa4f8c502:123zO3xZCLrMN6v2BKK1dXYFpXlPkccOFqm12CdAsMgRU4VrNZ9lyGVCGuMDGIwP
    " | sudo tee /users/$CURRENT_USER/.wskprops
    sudo chown $CURRENT_USER:$PROFILE_GROUP /users/$CURRENT_USER/.wskprops
    done
}

printf "%s: args=(" "$(date +"%T.%N")"
for var in "$@"
do
    printf "'%s' " "$var"
done
printf ")\n"

if [ $# -lt $NUM_MIN_ARGS ]; then
    echo "***Error: Expected at least $NUM_MIN_ARGS arguments."
    echo "$USAGE"
    exit -1
fi

if [ $1 != $PRIMARY_ARG -a $1 != $SECONDARY_ARG ] ; then
    echo "***Error: First arg should be '$PRIMARY_ARG' or '$SECONDARY_ARG'"
    echo "$USAGE"
    exit -1
fi

disable_swap

if test -d "/mydata"; then
    configure_docker_storage
fi

wait_for_apt_lock
sudo groupadd $PROFILE_GROUP
for FILE in /users/*; do
    CURRENT_USER=${FILE##*/}
    sudo gpasswd -a $CURRENT_USER $PROFILE_GROUP
    sudo gpasswd -a $CURRENT_USER docker
done
sudo chown -R $USER:$PROFILE_GROUP $INSTALL_DIR
sudo chmod -R g+rw $INSTALL_DIR

# --- SECONDARY NODE SETUP ---
if [ $1 == $SECONDARY_ARG ] ; then

    if [ "$3" == "False" ]; then
        printf "%s: %s\n" "$(date +"%T.%N")" "Start Kubernetes is $3, done!"
        exit 0
    fi
    
    cat /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$2/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    
    # ### FIX: Must reload daemon for new config to take effect
    sudo systemctl daemon-reload
    
    cat /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

    setup_secondary $2
    exit 0
fi

# --- PRIMARY NODE SETUP ---
if [ $# -ne $NUM_PRIMARY_ARGS ]; then
    echo "***Error: Expected at least $NUM_PRIMARY_ARGS arguments."
    echo "$USAGE"
    exit -1
fi

if [ "$4" = "False" ]; then
    printf "%s: %s\n" "$(date +"%T.%N")" "Start Kubernetes is $4, done!"
    exit 0
fi

cat /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$2/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# ### FIX: Must reload daemon for new config to take effect
sudo systemctl daemon-reload

cat /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

setup_primary $2
apply_calico
add_cluster_nodes $3

if [ "$5" = "False" ]; then
    printf "%s: %s\n" "$(date +"%T.%N")" "Deploy Openwhisk is $4, done!"
    exit 0
fi

prepare_for_openwhisk $2 $3 $6 $7 $8
deploy_openwhisk $2

printf "%s: %s\n" "$(date +"%T.%N")" "Profile setup completed!"