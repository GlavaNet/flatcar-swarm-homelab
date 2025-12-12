#!/bin/bash
# cluster-init.sh - Run once on manager-1 after swarm bootstrap

set -e

REPO_URL="https://github.com/GlavaNet/flatcar-swarm-homelab.git"
REPO_DIR="/home/core/flatcar-swarm-homelab"

echo "Cloning repository..."
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
fi

echo "Generating TLS certificates for local services..."
cd "$REPO_DIR"

# Run certificate generation script
if [ -f scripts/generate-local-certs.sh ]; then
    bash scripts/generate-local-certs.sh
else
    # Fallback to simple cert generation for vault
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
    else
        echo "ERROR: .env.template not found in repository"
        echo "Creating minimal .env.local..."
        
        cat > "$REPO_DIR/.env.local" << 'EOF'
# Tailscale Configuration
TAILNET_NAME=YOUR_TAILNET_HERE.ts.net
TAILSCALE_HOSTNAME=swarm-manager-1

# Network Configuration
CLUSTER_NETWORK=192.168.99.0/24
PRIMARY_MANAGER_IP=192.168.99.101

# Domain Configuration
LOCAL_DOMAIN=local
EOF
        
        echo "Created minimal .env.local - please edit it with your settings"
    fi
fi

echo "Deploying stacks..."
cd "$REPO_DIR"

# Only deploy if this is first run (check for marker file)
if [ ! -f /home/core/.cluster-initialized ]; then
    # Check if we should use env-aware deployment
    if [ -f scripts/deploy-services-env.sh ]; then
        echo "Using environment-aware deployment..."
        bash scripts/deploy-services-env.sh
    else
        echo "Using standard deployment..."
        bash scripts/deploy-services.sh
    fi
    
    touch /home/core/.cluster-initialized
    echo "Initial deployment complete"
else
    echo "Cluster already initialized, skipping stack deployment"
    echo "To redeploy: cd ~/flatcar-swarm-homelab && bash scripts/deploy-services-env.sh"
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

echo ""
echo "=== ntfy Notification Configuration ==="
echo ""
echo "Options:"
echo "  1. Use public ntfy.sh (works anywhere, no self-hosting)"
echo "  2. Use local ntfy.local (requires self-hosted ntfy or VPN)"
echo ""
read -p "Enter choice (1 or 2) [default: 2]: " ntfy_choice

if [ "$ntfy_choice" = "1" ]; then
    echo ""
    echo "Generate a random topic name with: echo \"swarm-\$(openssl rand -hex 6)-alerts\""
    echo ""
    read -p "Enter your ntfy.sh topic name (e.g., swarm-a3f8b2e1-alerts): " ntfy_topic
    
    if [ -z "$ntfy_topic" ]; then
        echo "ERROR: Topic name cannot be empty"
        exit 1
    fi
    
    NTFY_URL="https://ntfy.sh/$ntfy_topic"
    echo "Using: $NTFY_URL"
else
    NTFY_URL="http://ntfy.local/swarm-alerts"
    echo "Using: $NTFY_URL"
fi

# Store in environment
echo "NTFY_TOPIC_URL=$NTFY_URL" | sudo tee -a /etc/environment
echo ""

echo "Setting up git-poll auto-deployment with ntfy notifications..."

# Copy notification script
sudo cp /home/core/flatcar-swarm-homelab/scripts/git-deploy-notify.sh /opt/bin/
sudo chmod +x /opt/bin/git-deploy-notify.sh

sudo tee /etc/systemd/system/git-poll.service > /dev/null << 'SERVICE'
[Unit]
Description=Pull git changes and deploy with notifications
After=docker.service

[Service]
Type=oneshot
User=core
EnvironmentFile=/etc/environment
WorkingDirectory=/home/core/flatcar-swarm-homelab
ExecStart=/opt/bin/git-deploy-notify.sh

[Install]
WantedBy=multi-user.target
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
echo "IMPORTANT: Configure your .env.local file"
echo "  nano $REPO_DIR/.env.local"
echo ""
echo "Then redeploy services:"
echo "  cd $REPO_DIR && bash scripts/deploy-services-env.sh"
echo ""
echo "MANUAL STEPS REQUIRED:"
echo ""
echo "1. Add to your local /etc/hosts:"
echo "   192.168.99.101  git.local grafana.local prometheus.local alertmanager.local adguard.local vault.local traefik.local ha.local"
echo ""
if [ "$ntfy_choice" = "1" ]; then
    echo "2. Set up ntfy on your phone:"
    echo "   - Install ntfy app (iOS/Android)"
    echo "   - Server: https://ntfy.sh"
    echo "   - Topic: $ntfy_topic"
    echo "   - Enable notifications"
else
    echo "2. Set up ntfy on your phone:"
    echo "   - Install ntfy app (iOS/Android)"
    echo "   - Add custom server: http://ntfy.local (or http://192.168.99.101 if no DNS)"
    echo "   - Subscribe to topic: swarm-alerts"
    echo "   - Enable notifications"
fi
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
echo "   Local (HTTPS with self-signed cert - needs trust):"
echo "   - Vaultwarden: https://vault.local"
echo "   - Home Assistant: https://ha.local (also :8123)"
echo ""
echo "   Local (HTTP):"
echo "   - Traefik: http://traefik.local"
echo "   - Forgejo: http://git.local"
echo "   - Grafana: http://grafana.local (admin/admin)"
echo "   - Prometheus: http://prometheus.local"
echo "   - Alertmanager: http://alertmanager.local"
echo "   - AdGuard: http://adguard.local"
echo ""
echo "   Remote (via Tailscale with trusted certs):"
echo "   - Configure .env.local first, then:"
echo "   - https://vault.<hostname>.<tailnet>.ts.net"
echo "   - https://ha.<hostname>.<tailnet>.ts.net"
echo ""
echo "7. Trust local certificates (for HTTPS access):"
echo "   See: scripts/generate-local-certs.sh output for instructions"
echo ""
echo "8. Test notifications:"
if [ "$ntfy_choice" = "1" ]; then
    echo "   curl -d 'Hello from your Swarm cluster!' https://ntfy.sh/$ntfy_topic"
else
    echo "   curl -d 'Hello from your Swarm cluster!' http://ntfy.local/swarm-alerts"
fi
echo ""
