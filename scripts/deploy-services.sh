#!/bin/bash
# Simplified deployment script with proper environment handling

set -e

REPO_DIR="$HOME/flatcar-swarm-homelab"
cd "$REPO_DIR"

echo "=== Flatcar Swarm Deployment ==="
echo ""

# Load environment
if [ -f .env.local ]; then
    echo "Loading .env.local..."
    source .env.local
    export TAILNET_NAME TAILSCALE_HOSTNAME PRIMARY_MANAGER_IP LOCAL_DOMAIN
    echo "✓ Environment loaded"
else
    echo "WARNING: .env.local not found, using defaults"
    export TAILNET_NAME="tail1234a.ts.net"
    export TAILSCALE_HOSTNAME="swarm-manager-1"
    export PRIMARY_MANAGER_IP="192.168.99.101"
    export LOCAL_DOMAIN="local"
fi

echo ""
echo "Configuration:"
echo "  TAILNET_NAME: $TAILNET_NAME"
echo "  TAILSCALE_HOSTNAME: $TAILSCALE_HOSTNAME"
echo "  PRIMARY_MANAGER_IP: $PRIMARY_MANAGER_IP"
echo ""

# If NTFY_TOPIC_URL not set in .env.local, use or create ~/.ntfy-url
if [ -z "$NTFY_TOPIC_URL" ] && [ -f scripts/setup-ntfy-url.sh ]; then
    export NTFY_TOPIC_URL=$(bash scripts/setup-ntfy-url.sh)
    echo "  NTFY_TOPIC_URL: $NTFY_TOPIC_URL (auto-configured)"
fi

# Ensure certs directory exists
if [ ! -d /home/core/certs ]; then
    echo "Creating /home/core/certs..."
    sudo mkdir -p /home/core/certs
    sudo chown core:core /home/core/certs
fi

# Deploy Traefik
echo "=== Deploying Traefik ==="
cd "$REPO_DIR/stacks/traefik"

# Process dynamic config if it exists
if [ -f traefik-dynamic.yml ]; then
    echo "Processing traefik-dynamic.yml..."
    envsubst < traefik-dynamic.yml > /tmp/traefik-dynamic.yml
    sudo cp /tmp/traefik-dynamic.yml /home/core/certs/dynamic.yml
    rm /tmp/traefik-dynamic.yml
fi

# Deploy (use envsubst if stack file has variables, otherwise deploy directly)
if grep -q '\${' traefik-stack.yml; then
    envsubst < traefik-stack.yml | docker stack deploy -c - traefik
else
    docker stack deploy -c traefik-stack.yml traefik
fi

echo "✓ Traefik deployed"
sleep 5

# Deploy Forgejo
echo ""
echo "=== Deploying Forgejo ==="
cd "$REPO_DIR/stacks/forgejo"
docker stack deploy -c forgejo-stack.yml forgejo
echo "✓ Forgejo deployed"

# Deploy Monitoring
echo ""

# Substitute ntfy URL in alertmanager.yml
if [ -n "$NTFY_TOPIC_URL" ]; then
    echo "Configuring alertmanager with ntfy notifications..."
    sed "s|{{NTFY_TOPIC_URL}}|$NTFY_TOPIC_URL|g" \
        stacks/monitoring/alertmanager.yml > /tmp/alertmanager.yml.tmp
    mv /tmp/alertmanager.yml.tmp stacks/monitoring/alertmanager.yml
fi

echo "=== Deploying Monitoring ==="
cd "$REPO_DIR/stacks/monitoring"
docker stack deploy -c monitoring-stack.yml monitoring
echo "✓ Monitoring deployed"

# Deploy Vaultwarden
echo ""
echo "=== Deploying Vaultwarden ==="
cd "$REPO_DIR/stacks/vaultwarden"
if grep -q '\${' vaultwarden-stack.yml; then
    envsubst < vaultwarden-stack.yml | docker stack deploy -c - vaultwarden
else
    docker stack deploy -c vaultwarden-stack.yml vaultwarden
fi
echo "✓ Vaultwarden deployed"

# Deploy Home Assistant
echo ""
echo "=== Deploying Home Assistant ==="
cd "$REPO_DIR/stacks/homeassistant"
docker stack deploy -c homeassistant-stack.yml homeassistant
echo "✓ Home Assistant deployed"

# Deploy Mealie
echo ""
echo "=== Deploying Mealie ==="
cd "$REPO_DIR/stacks/mealie"
docker stack deploy -c mealie-stack.yml mealie
echo "✓ Mealie deployed"

# Deploy MinIO (if exists)
if [ -d "$REPO_DIR/stacks/minio" ]; then
    echo ""
    echo "=== Deploying MinIO ==="
    cd "$REPO_DIR/stacks/minio"
    
    # Check for password
    if [ ! -f ~/.minio-password ]; then
        MINIO_PASSWORD=$(openssl rand -base64 24)
        echo "$MINIO_PASSWORD" > ~/.minio-password
        chmod 600 ~/.minio-password
        echo "Generated MinIO password: $MINIO_PASSWORD"
    fi
    
    export MINIO_PASSWORD=$(cat ~/.minio-password)
    
    if [ -f minio-stack.yml ]; then
        envsubst < minio-stack.yml | docker stack deploy -c - minio
        echo "✓ MinIO deployed"
    fi
fi

# Deploy AdGuard (if secrets exist)
if docker secret inspect adguard_username >/dev/null 2>&1; then
    echo ""
    echo "=== Deploying AdGuard ==="
    cd "$REPO_DIR/stacks/adguard"
    docker stack deploy -c adguard-stack.yml adguard
    echo "✓ AdGuard deployed"
else
    echo ""
    echo "⚠️  Skipping AdGuard (secrets not configured)"
    echo "Run: ./scripts/setup-adguard-secrets.sh"
fi

# Deploy Tailscale (if secret exists)
if docker secret inspect tailscale_auth_key >/dev/null 2>&1; then
    echo ""
    echo "=== Deploying Tailscale ==="
    cd "$REPO_DIR/stacks/tailscale"
    docker stack deploy -c tailscale-stack.yml tailscale
    echo "✓ Tailscale deployed"
else
    echo ""
    echo "⚠️  Skipping Tailscale (secret not configured)"
    echo "Run: ./scripts/setup-tailscale-secrets.sh"
fi

# Deploy JIT infrastructure (if exists)
if [ -d "$REPO_DIR/stacks/webhook-receiver" ]; then
    echo ""
    echo "=== Deploying JIT Infrastructure ==="
    
    cd "$REPO_DIR/stacks/webhook-receiver"
    docker stack deploy -c webhook-receiver-stack.yml webhook-receiver
    echo "✓ Webhook receiver deployed"
    
    cd "$REPO_DIR/stacks/jit-catchall"
    docker stack deploy -c jit-catchall-stack.yml jit-catchall
    echo "✓ JIT catchall deployed"
fi

# Scale JIT services to 0 (if JIT is configured)
if [ -x /opt/bin/jit-services.sh ]; then
    echo ""
    echo "=== Configuring JIT Services ==="
    
    # Wait a moment for services to be created
    sleep 5
    
    for service in mealie_mealie forgejo_forgejo vaultwarden_vaultwarden minio_minio; do
        if docker service ls | grep -q "$service"; then
            echo "Scaling $service to 0..."
            docker service scale "${service}=0" 2>/dev/null || true
        fi
    done
    
    echo "✓ JIT services scaled to 0"
fi

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Services:"
docker service ls
echo ""
echo "Access services at:"
echo "  http://traefik.local - Traefik dashboard"
echo "  http://git.local - Forgejo"
echo "  http://grafana.local - Grafana"
echo "  http://prometheus.local - Prometheus"
echo "  http://vault.local - Vaultwarden"
echo "  http://ha.local - Home Assistant"
echo "  http://recipes.local - Mealie (JIT)"
echo ""
