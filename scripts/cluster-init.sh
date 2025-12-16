#!/bin/bash
# cluster-init.sh - Run once on manager-1 after swarm bootstrap

set -e

REPO_URL="https://github.com/GlavaNet/flatcar-swarm-homelab.git"
REPO_DIR="/home/core/flatcar-swarm-homelab"
MANAGER_NODES=("192.168.99.102" "192.168.99.103")

echo "Cloning repository..."
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

echo "=== Setting up SSH keys between nodes ==="

# Generate SSH key on manager-1 if missing
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    echo "Generated SSH key on manager-1"
fi

# Distribute keys between all managers
for node in "${MANAGER_NODES[@]}"; do
    echo "Setting up keys with $node..."
    
    # Copy manager-1's key to other node
    cat ~/.ssh/id_rsa.pub | ssh core@$node "cat >> ~/.ssh/authorized_keys"
    
    # Generate key on remote node if missing and copy back
    ssh core@$node 'if [ ! -f ~/.ssh/id_rsa ]; then ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa; fi && cat ~/.ssh/id_rsa.pub' >> ~/.ssh/authorized_keys
done

# Copy keys between manager-2 and manager-3
ssh core@192.168.99.102 "cat ~/.ssh/id_rsa.pub" | ssh core@192.168.99.103 "cat >> ~/.ssh/authorized_keys"
ssh core@192.168.99.103 "cat ~/.ssh/id_rsa.pub" | ssh core@192.168.99.102 "cat >> ~/.ssh/authorized_keys"

# Remove duplicates on all nodes
for node in 192.168.99.101 "${MANAGER_NODES[@]}"; do
    if [ "$node" = "192.168.99.101" ]; then
        sort -u ~/.ssh/authorized_keys > /tmp/auth && mv /tmp/auth ~/.ssh/authorized_keys
    else
        ssh core@$node 'sort -u ~/.ssh/authorized_keys > /tmp/auth && mv /tmp/auth ~/.ssh/authorized_keys'
    fi
done

echo "✓ SSH keys distributed"

echo "=== Generating TLS certificates ==="
if [ -f scripts/generate-local-certs.sh ]; then
    bash scripts/generate-local-certs.sh
else
    mkdir -p /home/core/certs
    if [ ! -f /home/core/certs/vault.crt ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /home/core/certs/vault.key \
            -out /home/core/certs/vault.crt \
            -subj "/CN=vault.local" \
            -addext "subjectAltName=DNS:vault.local" \
            2>/dev/null
    fi
fi

echo "=== Deploying MinIO ==="

# Generate MinIO password
if [ ! -f ~/.minio-password ]; then
    MINIO_PASSWORD=$(openssl rand -base64 24)
    echo "$MINIO_PASSWORD" > ~/.minio-password
    chmod 600 ~/.minio-password
    echo "MinIO password: $MINIO_PASSWORD"
else
    MINIO_PASSWORD=$(cat ~/.minio-password)
fi

# Create MinIO stack file with password
sed "s/\${MINIO_PASSWORD}/$MINIO_PASSWORD/g" \
    stacks/minio/minio-stack.yml > /tmp/minio-deploy.yml

docker stack deploy -c /tmp/minio-deploy.yml minio
rm /tmp/minio-deploy.yml

echo "Waiting for MinIO to start..."
sleep 30

# Create backups bucket
docker run --rm --network host --entrypoint /bin/sh minio/mc:latest \
    -c "mc alias set homelab http://localhost:9000 minioadmin ${MINIO_PASSWORD} && mc mb homelab/backups"

echo "✓ MinIO deployed with backups bucket"

echo "=== Installing backup services ==="

# Copy backup script
sudo cp scripts/backup-to-minio.sh /opt/bin/
sudo chmod +x /opt/bin/backup-to-minio.sh

# Create service
sudo tee /etc/systemd/system/minio-backup.service > /dev/null << 'EOF'
[Unit]
Description=Backup volumes to MinIO
After=docker.service

[Service]
Type=oneshot
User=core
Group=core
ExecStart=/opt/bin/backup-to-minio.sh
StandardOutput=journal
StandardError=journal
EOF

# Create timer
sudo tee /etc/systemd/system/minio-backup.timer > /dev/null << 'EOF'
[Unit]
Description=Daily MinIO backup

[Timer]
OnCalendar=02:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable minio-backup.timer
sudo systemctl start minio-backup.timer

echo "✓ MinIO backup service installed"

echo "=== Installing volume replication service ==="

sudo cp scripts/replicate-volumes.sh /opt/bin/
sudo chmod +x /opt/bin/replicate-volumes.sh

sudo tee /etc/systemd/system/volume-replication.service > /dev/null << 'EOF'
[Unit]
Description=Replicate Docker volumes to backup managers
After=docker.service

[Service]
Type=oneshot
User=core
Group=core
ExecStart=/opt/bin/replicate-volumes.sh
StandardOutput=journal
StandardError=journal
EOF

sudo tee /etc/systemd/system/volume-replication.timer > /dev/null << 'EOF'
[Unit]
Description=Daily volume replication

[Timer]
OnCalendar=03:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable volume-replication.timer
sudo systemctl start volume-replication.timer

echo "✓ Volume replication service installed"

# Create .env.local if it doesn't exist
if [ ! -f "$REPO_DIR/.env.local" ]; then
    echo ""
    echo "=== Environment Configuration Setup ==="
    echo ""
    
    if [ -f "$REPO_DIR/.env.template" ]; then
        cp "$REPO_DIR/.env.template" "$REPO_DIR/.env.local"
        
        echo "Created .env.local from template"
        echo ""
        echo "You need to configure your Tailscale settings:"
        echo "  nano $REPO_DIR/.env.local"
        echo ""
        echo "Required settings:"
        echo "  - TAILNET_NAME: Your Tailscale network name (e.g., tail1234a.ts.net)"
        echo "  - TAILSCALE_HOSTNAME: This node's hostname (e.g., swarm-manager-1)"
        echo ""
        echo "To find your Tailnet name after deploying Tailscale:"
        echo "  docker exec \$(docker ps -q -f name=tailscale) tailscale status | head -1"
        echo ""
    fi
fi

echo "Deploying stacks..."

# Only deploy if this is first run
if [ ! -f /home/core/.cluster-initialized ]; then
    if [ -f scripts/deploy-services-env.sh ]; then
        bash scripts/deploy-services-env.sh
    else
        bash scripts/deploy-services.sh
    fi
    
    touch /home/core/.cluster-initialized
    echo "Initial deployment complete"
else
    echo "Cluster already initialized, skipping stack deployment"
fi

echo ""
echo "=== Cluster initialization complete ==="
echo ""
echo "MinIO:"
echo "  Console: http://minio.local or http://192.168.99.101:9001"
echo "  Username: minioadmin"
echo "  Password: $(cat ~/.minio-password)"
echo ""
echo "Backup schedule:"
echo "  MinIO backup: Daily at 2:00 AM"
echo "  Volume replication: Daily at 3:00 AM"
echo ""
echo "Manual backup:"
echo "  sudo systemctl start minio-backup.service"
echo "  sudo systemctl start volume-replication.service"
echo ""
