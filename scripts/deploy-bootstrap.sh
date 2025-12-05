#!/bin/bash
# Deploy swarm bootstrap to running Flatcar nodes

set -e

NODES=(
    "192.168.99.101:swarm-manager-1:manager"
    "192.168.99.102:swarm-manager-2:manager"
    "192.168.99.103:swarm-manager-3:manager"
    "192.168.99.111:swarm-worker-1:worker"
)

BOOTSTRAP_SCRIPT="./swarm-bootstrap.sh"
CLUSTER_INIT_SCRIPT="./cluster-init.sh"

if [ ! -f "$BOOTSTRAP_SCRIPT" ]; then
    echo "Error: $BOOTSTRAP_SCRIPT not found"
    exit 1
fi

if [ ! -f "$CLUSTER_INIT_SCRIPT" ]; then
    echo "Warning: $CLUSTER_INIT_SCRIPT not found, skipping cluster init"
fi

echo "=== Deploying Swarm Bootstrap to Nodes ==="
echo ""

for node_info in "${NODES[@]}"; do
    IFS=':' read -r ip hostname role <<< "$node_info"
    
    echo "Deploying to $hostname ($ip)..."
    
    # Copy bootstrap script
    scp -o StrictHostKeyChecking=no "$BOOTSTRAP_SCRIPT" core@$ip:/tmp/swarm-bootstrap.sh
    
    # Copy cluster-init script only to manager-1
    if [ "$hostname" = "swarm-manager-1" ] && [ -f "$CLUSTER_INIT_SCRIPT" ]; then
        echo "  Copying cluster-init.sh to manager-1..."
        scp -o StrictHostKeyChecking=no "$CLUSTER_INIT_SCRIPT" core@$ip:/home/core/
        ssh -o StrictHostKeyChecking=no core@$ip 'chmod +x /home/core/cluster-init.sh'
    fi
    
    # Install and configure
    ssh -o StrictHostKeyChecking=no core@$ip << 'EOF'
sudo mkdir -p /opt/bin
sudo mv /tmp/swarm-bootstrap.sh /opt/bin/swarm-bootstrap.sh
sudo chmod +x /opt/bin/swarm-bootstrap.sh

# Add core to docker group
sudo usermod -aG docker core

# Create systemd unit
sudo tee /etc/systemd/system/swarm-bootstrap.service > /dev/null << 'UNIT'
[Unit]
Description=Docker Swarm Bootstrap
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/environment
ExecStart=/opt/bin/swarm-bootstrap.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=600
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable swarm-bootstrap.service
sudo systemctl start swarm-bootstrap.service
EOF
    
    echo "✓ $hostname complete"
    echo ""
done

echo "=== Bootstrap Deployment Complete ==="
echo ""
echo "Waiting 30 seconds for swarm to form..."
sleep 30

echo "Running cluster initialization on manager-1..."
ssh -o StrictHostKeyChecking=no core@192.168.99.101 '/home/core/cluster-init.sh' || {
    echo "Warning: cluster-init.sh not found or failed"
    echo "Run manually: ssh core@192.168.99.101 '/home/core/cluster-init.sh'"
}

echo ""
echo "=== Cluster Setup Complete ==="
echo "Check cluster status:"
echo "  ssh core@192.168.99.101 'docker node ls'"
echo ""
