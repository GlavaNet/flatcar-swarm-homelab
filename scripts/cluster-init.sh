#!/bin/bash
# cluster-init.sh - Run once on manager-1 after swarm bootstrap

set -e

REPO_URL="https://github.com/GlavaNet/flatcar-swarm-homelab.git"
REPO_DIR="/home/core/flatcar-swarm-homelab"

echo "Cloning repository..."
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
fi

echo "Generating TLS certificates..."
mkdir -p /home/core/certs
if [ ! -f /home/core/certs/vault.crt ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /home/core/certs/vault.key \
        -out /home/core/certs/vault.crt \
        -subj "/CN=vault.local" 2>/dev/null
fi

cat > /home/core/certs/dynamic.yml << 'EOF'
tls:
  certificates:
    - certFile: /certs/vault.crt
      keyFile: /certs/vault.key
EOF

echo "Deploying stacks..."
cd "$REPO_DIR"

# Deploy ntfy first for notifications
if [ ! -f /home/core/.ntfy-deployed ]; then
    echo "Deploying ntfy notification service..."
    docker stack deploy -c stacks/ntfy/ntfy-stack.yml ntfy
    sleep 10
    touch /home/core/.ntfy-deployed
fi

# Only deploy other services if this is first run
if [ ! -f /home/core/.cluster-initialized ]; then
    bash scripts/deploy-services.sh
    touch /home/core/.cluster-initialized
    echo "Initial deployment complete"
else
    echo "Cluster already initialized, skipping stack deployment"
    echo "To redeploy: ssh to manager-1 and run: cd ~/flatcar-swarm-homelab && bash scripts/deploy-services.sh"
fi

echo "Waiting for Forgejo to start..."
sleep 30

echo "Configuring Forgejo mirror sync..."
cat > /tmp/forgejo-sync.sh << 'SCRIPT'
#!/bin/bash
CONTAINER=$(docker ps -q -f name=forgejo_forgejo)
if [ -n "$CONTAINER" ]; then
  docker exec "$CONTAINER" su git -c "forgejo admin mirror-sync"
fi
SCRIPT

sudo mv /tmp/forgejo-sync.sh /opt/bin/forgejo-sync.sh
sudo chmod +x /opt/bin/forgejo-sync.sh

sudo tee /etc/systemd/system/forgejo-mirror-sync.service > /dev/null << 'SERVICE'
[Unit]
Description=Sync Forgejo mirrors from GitHub

[Service]
Type=oneshot
ExecStart=/opt/bin/forgejo-sync.sh
SERVICE

sudo tee /etc/systemd/system/forgejo-mirror-sync.timer > /dev/null << 'TIMER'
[Unit]
Description=Sync Forgejo mirrors every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now forgejo-mirror-sync.timer

echo "Setting up git-poll auto-deployment with ntfy notifications..."

# Copy notification script
sudo cp /home/core/flatcar-swarm-homelab/scripts/git-deploy-notify.sh /opt/bin/
sudo chmod +x /opt/bin/git-deploy-notify.sh

sudo tee /etc/systemd/system/git-poll.service > /dev/null << 'SERVICE'
[Unit]
Description=Pull git changes and deploy with notifications
After=docker.service ntfy.service

[Service]
Type=oneshot
User=core
WorkingDirectory=/home/core/flatcar-swarm-homelab
ExecStart=/opt/bin/git-deploy-notify.sh
SERVICE

sudo tee /etc/systemd/system/git-poll.timer > /dev/null << 'TIMER'
[Unit]
Description=Poll git repo every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now git-poll.timer

echo ""
echo "=== Cluster initialization complete ==="
echo ""
echo "MANUAL STEPS REQUIRED:"
echo ""
echo "1. Add to your local /etc/hosts:"
echo "   192.168.99.101  git.local grafana.local prometheus.local alertmanager.local adguard.local vault.local traefik.local ntfy.local"
echo ""
echo "2. Set up ntfy on your phone:"
echo "   - Install ntfy app (iOS/Android)"
echo "   - Add custom server: http://ntfy.local (or http://192.168.99.101 if no DNS)"
echo "   - Subscribe to topic: swarm-alerts"
echo "   - Enable notifications"
echo ""
echo "3. Visit http://192.168.99.101:3000 to complete Forgejo initial setup"
echo "   - Create admin account (username: admin recommended)"
echo ""
echo "4. Create GitHub repo mirror in Forgejo:"
echo "   + → New Migration → GitHub"
echo "   - Clone URL: https://github.com/GlavaNet/flatcar-swarm-homelab"
echo "   - Check 'This repository will be a mirror'"
echo ""
echo "5. Automated CI/CD is configured:"
echo "   - Forgejo syncs from GitHub every 10 minutes"
echo "   - Git-poll deploys changes every 5 minutes"
echo "   - Push to GitHub → auto-deploys to cluster"
echo "   - All deployment events sent to ntfy"
echo ""
echo "6. Access services:"
echo "   - Traefik: http://traefik.local"
echo "   - Forgejo: http://git.local"
echo "   - Grafana: http://grafana.local (admin/admin)"
echo "   - Prometheus: http://prometheus.local"
echo "   - Alertmanager: http://alertmanager.local"
echo "   - AdGuard: http://adguard.local"
echo "   - Vaultwarden: http://vault.local"
echo "   - ntfy: http://ntfy.local"
echo ""
echo "7. Test notifications:"
echo "   curl -d 'Hello from your Swarm cluster!' http://ntfy.local/swarm-alerts"
echo ""
