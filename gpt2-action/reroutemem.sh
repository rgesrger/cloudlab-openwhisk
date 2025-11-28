#!/bin/bash
# Script to move Docker storage to /mydata/docker on CloudLab nodes

set -e  # Exit on any error

echo "=== 1. Creating Docker storage directory ==="
sudo mkdir -p /mydata/docker

echo "=== 2. Fixing permissions ==="
sudo chmod 711 /mydata
sudo chmod 711 /mydata/docker
sudo chown root:root /mydata/docker

echo "=== 3. Backing up existing daemon.json ==="
if [ -f /etc/docker/daemon.json ]; then
    sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
    echo "Backup saved to /etc/docker/daemon.json.bak"
fi

echo "=== 4. Writing new daemon.json ==="
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "data-root": "/mydata/docker"
}
EOF

echo "=== 5. Cleaning old Docker data in new location (optional) ==="
sudo rm -rf /mydata/docker/*

echo "=== 6. Restarting Docker ==="
sudo systemctl restart docker

echo "=== 7. Verify Docker Root Dir ==="
docker info | grep "Docker Root Dir"

echo "=== Done! Docker storage is now on /mydata/docker ==="
