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

if [ ! -f "$BOOTSTRAP_SCRIPT" ]; then
    echo "Error: $BOOTSTRAP_SCRIPT not found"
    exit 1
fi

echo "=== Deploying Swarm Bootstrap to Nodes ==="
echo ""

for node_info in "${NODES[@]}"; do
    IFS=':' read -r ip hostname role <<< "$node_info"
    
    echo "Deploying to $hostname ($ip)..."
    
    # Copy bootstrap script
    scp -o StrictHostKeyChecking=no "$BOOTSTRAP_SCRIPT" core@$ip:/tmp/swarm-bootstrap.sh
    
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
echo "Check cluster status:"
echo "  ssh core@192.168.99.101 'docker node ls'"
echo ""
