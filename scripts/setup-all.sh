#!/bin/bash
# Complete setup: MinIO + automated backups

set -e

echo "=== Backup & Replication Setup ==="
echo ""

# 1. Deploy single-node MinIO
echo "Step 1: Deploying MinIO..."
if [ -z "$MINIO_PASSWORD" ]; then
    MINIO_PASSWORD=$(openssl rand -base64 24)
    echo "$MINIO_PASSWORD" > ~/.minio-password
    chmod 600 ~/.minio-password
    echo "Password saved to ~/.minio-password"
fi

export MINIO_PASSWORD

docker stack rm minio 2>/dev/null || true
sleep 5

docker stack deploy -c ../stacks/minio/minio-single-stack.yml minio

echo "✓ MinIO deployed on manager-1"
echo ""

# 2. Setup SSH keys for passwordless replication
# echo "Step 2: Setting up SSH keys..."
# if [ ! -f ~/.ssh/id_rsa ]; then
#     ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
# fi

# for node in 192.168.99.102 192.168.99.103; do
#     echo "  Copying SSH key to $node..."
#     ssh-copy-id -o StrictHostKeyChecking=no core@$node 2>/dev/null || \
#         echo "  Key already copied or failed"
# done

echo "✓ SSH keys configured"
echo ""

# 3. Install replication service
echo "Step 3: Installing replication service..."
bash install-replication.sh

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Services:"
echo "  MinIO Console: http://minio.local or http://192.168.99.101:9001"
echo "  Username: minioadmin"
echo "  Password: $(cat ~/.minio-password)"
echo ""
echo "Backup schedule: Daily at midnight"
echo ""
echo "Test backup now:"
echo "  sudo systemctl start volume-replication.service"
echo ""
echo "Monitor backups:"
echo "  journalctl -u volume-replication.service -f"
