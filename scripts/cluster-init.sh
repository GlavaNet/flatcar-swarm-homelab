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

# Only deploy if this is first run (check for marker file)
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
sudo tee /etc/systemd/system/forgejo-mirror-sync.service > /dev/null << 'SERVICE'
[Unit]
Description=Sync Forgejo mirrors from GitHub

[Service]
Type=oneshot
ExecStart=/usr/bin/docker exec $(docker ps -q -f name=forgejo_forgejo) su git -c "forgejo admin mirror-sync"
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

echo "Setting up git-poll auto-deployment..."
sudo tee /etc/systemd/system/git-poll.service > /dev/null << 'SERVICE'
[Unit]
Description=Pull git changes and deploy
After=docker.service

[Service]
Type=oneshot
User=core
WorkingDirectory=/home/core/flatcar-swarm-homelab
ExecStart=/bin/bash -c 'git fetch origin && git reset --hard origin/main && bash scripts/deploy-services.sh'
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
echo "   192.168.99.101  git.local grafana.local prometheus.local adguard.local vault.local traefik.local"
echo ""
echo "2. Visit http://192.168.99.101:3000 to complete Forgejo initial setup"
echo "   - Create admin account (username: admin recommended)"
echo ""
echo "3. Create GitHub repo mirror in Forgejo:"
echo "   + → New Migration → GitHub"
echo "   - Clone URL: https://github.com/GlavaNet/flatcar-swarm-homelab"
echo "   - Check 'This repository will be a mirror'"
echo ""
echo "4. Automated CI/CD is configured:"
echo "   - Forgejo syncs from GitHub every 10 minutes"
echo "   - Git-poll deploys changes every 5 minutes"
echo "   - Push to GitHub → auto-deploys to cluster"
echo ""
echo "5. Access services:"
echo "   - Traefik: http://traefik.local"
echo "   - Forgejo: http://git.local"
echo "   - Grafana: http://grafana.local (admin/admin)"
echo "   - Prometheus: http://prometheus.local"
echo "   - AdGuard: http://adguard.local"
echo "   - Vaultwarden: http://vault.local"
echo ""
