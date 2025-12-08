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
bash scripts/deploy-services.sh

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

echo "Setting up auto-deployment..."
sudo cp /home/core/git-autodeploy.sh /opt/bin/
sudo chmod +x /opt/bin/git-autodeploy.sh

# Create systemd service
sudo tee /etc/systemd/system/git-autodeploy.service > /dev/null << 'SERVICE'
[Unit]
Description=Git Auto Deploy
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/bin/git-autodeploy.sh
User=core
SERVICE

# Create systemd timer (checks every 5 minutes)
sudo tee /etc/systemd/system/git-autodeploy.timer > /dev/null << 'TIMER'
[Unit]
Description=Git Auto Deploy Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now git-autodeploy.timer

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
echo "3. Create OAuth app for Drone in Forgejo:"
echo "   Settings → Applications → Create OAuth2 Application"
echo "   - Application Name: Drone CI"
echo "   - Redirect URI: http://192.168.99.101:8080/login"
echo "   - Copy Client ID and Client Secret"
echo ""
echo "4. Update drone-stack.yml with OAuth credentials:"
echo "   ssh core@192.168.99.101"
echo "   cd ~/flatcar-swarm-homelab/stacks/drone"
echo "   nano drone-stack.yml"
echo "   (Update DRONE_GITEA_CLIENT_ID and DRONE_GITEA_CLIENT_SECRET)"
echo ""
echo "5. Create GitHub repo mirror in Forgejo:"
echo "   + → New Migration → GitHub"
echo "   - Clone URL: https://github.com/GlavaNet/flatcar-swarm-homelab"
echo "   - Check 'This repository will be a mirror'"
echo ""
echo "6. Redeploy Drone with updated credentials:"
echo "   docker stack deploy -c ~/flatcar-swarm-homelab/stacks/drone/drone-stack.yml drone"
echo ""
echo "7. Activate repository in Drone CI at http://192.168.99.101:8080"
echo ""
