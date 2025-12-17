#!/bin/bash
# Install Just-in-Time Service Management System

set -e

echo "=== Installing JIT Service Management ==="
echo ""

# Copy scripts
sudo cp jit-services.sh /opt/bin/
sudo cp webhook-receiver.py /opt/bin/
sudo cp backup-to-minio-jit.sh /opt/bin/
sudo chmod +x /opt/bin/jit-services.sh
sudo chmod +x /opt/bin/webhook-receiver.py
sudo chmod +x /opt/bin/backup-to-minio-jit.sh

# Replace old backup script
sudo cp /opt/bin/backup-to-minio.sh /opt/bin/backup-to-minio.sh.old || true
sudo cp /opt/bin/backup-to-minio-jit.sh /opt/bin/backup-to-minio.sh

# Install systemd units
sudo cp jit-checker.service /etc/systemd/system/
sudo cp jit-checker.timer /etc/systemd/system/
sudo cp webhook-receiver.service /etc/systemd/system/

# Generate webhook secret
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo "$WEBHOOK_SECRET" > ~/.webhook-secret
chmod 600 ~/.webhook-secret

# Update webhook service with secret
sudo sed -i "s/your-secret-here-change-me/$WEBHOOK_SECRET/" /etc/systemd/system/webhook-receiver.service

# Create JIT services directory
mkdir -p /home/core/jit-services

# Reload systemd
sudo systemctl daemon-reload

# Enable and start services
sudo systemctl enable jit-checker.timer
sudo systemctl start jit-checker.timer

sudo systemctl enable webhook-receiver.service
sudo systemctl start webhook-receiver.service

# Scale down JIT services to 0 initially
echo ""
echo "Scaling down JIT services to 0 replicas..."
docker service scale minio_minio=0 2>/dev/null || echo "MinIO not yet deployed"
docker service scale forgejo_forgejo=0 2>/dev/null || echo "Forgejo not yet deployed"
docker service scale mealie_mealie=0 2>/dev/null || echo "Mealie not yet deployed"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "JIT Service Management Commands:"
echo "  /opt/bin/jit-services.sh status          - Show service status"
echo "  /opt/bin/jit-services.sh start <service> - Start a service"
echo "  /opt/bin/jit-services.sh stop <service>  - Stop a service"
echo ""
echo "Available services:"
echo "  - minio_minio (30min timeout)"
echo "  - forgejo_forgejo (60min timeout)"
echo "  - mealie_mealie (60min timeout)"
echo ""
echo "Webhook endpoints (on port 9999):"
echo "  http://192.168.99.101:9999/github/forgejo  - GitHub webhook"
echo "  http://192.168.99.101:9999/start/minio     - Start MinIO"
echo "  http://192.168.99.101:9999/start/mealie    - Start Mealie"
echo ""
echo "Webhook secret (save this for GitHub):"
echo "  $WEBHOOK_SECRET"
echo ""
echo "To configure GitHub webhook:"
echo "  1. Go to your GitHub repo settings"
echo "  2. Webhooks → Add webhook"
echo "  3. Payload URL: http://YOUR_PUBLIC_IP:9999/github/forgejo"
echo "  4. Content type: application/json"
echo "  5. Secret: $WEBHOOK_SECRET"
echo "  6. Events: push, pull_request, release"
echo ""
echo "Backup system:"
echo "  - MinIO will auto-start before backups"
echo "  - MinIO will auto-stop 30min after backup completes"
echo ""
