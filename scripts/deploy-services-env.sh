#!/bin/bash
# Deploy services with environment variable substitution

set -e
cd "$(dirname "$0")/.."

NTFY_ENABLED=false

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting deployment with env substitution"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"

# Load system environment
if [ -f /etc/environment ]; then
    source /etc/environment
fi

# Load local environment configuration
if [ -f .env.local ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Loading local environment from .env.local"
    source .env.local
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: .env.local not found"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Copy .env.template to .env.local and configure it"
    
    if [ ! -f .env.template ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: .env.template not found"
        exit 1
    fi
    
    echo ""
    read -p "Create .env.local from template now? (y/n): " create_env
    
    if [ "$create_env" = "y" ]; then
        cp .env.template .env.local
        echo ""
        echo "Please edit .env.local with your configuration:"
        echo "  nano .env.local"
        echo ""
        echo "Then run this script again."
        exit 0
    else
        exit 1
    fi
fi

# Validate required variables
REQUIRED_VARS=("TAILNET_NAME" "TAILSCALE_HOSTNAME" "PRIMARY_MANAGER_IP")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Required variable $var not set in .env.local"
        exit 1
    fi
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuration loaded:"
echo "  TAILNET_NAME: $TAILNET_NAME"
echo "  TAILSCALE_HOSTNAME: $TAILSCALE_HOSTNAME"
echo "  PRIMARY_MANAGER_IP: $PRIMARY_MANAGER_IP"

# Function to substitute variables in stack files
substitute_and_deploy() {
    local stack_name="$1"
    local stack_file="$2"
    local temp_file="/tmp/${stack_name}-stack.yml"
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing $stack_name..."
    
    # Substitute environment variables
    envsubst < "$stack_file" > "$temp_file"
    
    # Deploy
    docker stack deploy -c "$temp_file" "$stack_name"
    
    # Clean up
    rm -f "$temp_file"
}

# Function to send ntfy notification
send_notification() {
    if [ "$NTFY_ENABLED" = "true" ] && [ -n "$NTFY_TOPIC_URL" ]; then
        local title="$1"
        local message="$2"
        local priority="${3:-default}"
        local tags="${4:-rocket}"
        
        curl -H "Title: ${title}" \
             -H "Priority: ${priority}" \
             -H "Tags: ${tags}" \
             -d "${message}" \
             "${NTFY_TOPIC_URL}" 2>/dev/null || true
    fi
}

# Check if Tailscale secret exists
if ! docker secret inspect tailscale_auth_key >/dev/null 2>&1; then
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tailscale auth key not found"
    echo ""
    read -p "Set up Tailscale now? (y/n): " setup_tailscale
    
    if [ "$setup_tailscale" = "y" ]; then
        ./scripts/setup-tailscale-secrets.sh
    else
        echo "Skipping Tailscale deployment"
        SKIP_TAILSCALE=true
    fi
fi

# Check if AdGuard secrets exist
if ! docker secret inspect adguard_username >/dev/null 2>&1; then
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard secrets not found"
    echo ""
    read -p "Set up AdGuard credentials now? (y/n): " setup_adguard
    
    if [ "$setup_adguard" = "y" ]; then
        ./scripts/setup-adguard-secrets.sh
    else
        echo "Skipping AdGuard deployment"
        SKIP_ADGUARD=true
    fi
fi

# Deploy core infrastructure first
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Traefik (reverse proxy)..."

# Process traefik-dynamic.yml separately
if [ -f stacks/traefik/traefik-dynamic.yml ]; then
    envsubst < stacks/traefik/traefik-dynamic.yml > /tmp/traefik-dynamic.yml
    sudo cp /tmp/traefik-dynamic.yml /home/core/certs/dynamic.yml || cp /tmp/traefik-dynamic.yml stacks/traefik/traefik-dynamic-processed.yml
    rm -f /tmp/traefik-dynamic.yml
fi

substitute_and_deploy "traefik" "stacks/traefik/traefik-stack.yml"
sleep 5

# Check if ntfy is accessible
if [ -n "$NTFY_TOPIC_URL" ]; then
    if curl -s --max-time 5 "${NTFY_TOPIC_URL}" > /dev/null 2>&1; then
        NTFY_ENABLED=true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ntfy is accessible, notifications enabled"
        send_notification "Deployment Started" "Cluster deployment in progress..." "default" "rocket"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ntfy not accessible, notifications disabled"
    fi
fi

# Deploy Tailscale (optional VPN access)
if [ "$SKIP_TAILSCALE" != "true" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Tailscale (VPN)..."
    substitute_and_deploy "tailscale" "stacks/tailscale/tailscale-stack.yml"
    send_notification "Tailscale Deployed" "VPN access configured" "default" "lock"
fi

# Deploy application services
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Forgejo (Git server)..."
substitute_and_deploy "forgejo" "stacks/forgejo/forgejo-stack.yml"
send_notification "Forgejo Deployed" "Git server is running" "default" "git"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Monitoring (Prometheus + Grafana + Alertmanager)..."

# Substitute ntfy URL in alertmanager config before deploying
if [ -n "$NTFY_TOPIC_URL" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring Alertmanager with ntfy URL..."
    sed "s|{{NTFY_TOPIC_URL}}|$NTFY_TOPIC_URL|g" \
        stacks/monitoring/alertmanager.yml > /tmp/alertmanager.yml.tmp
    mv /tmp/alertmanager.yml.tmp stacks/monitoring/alertmanager.yml
fi

substitute_and_deploy "monitoring" "stacks/monitoring/monitoring-stack.yml"
send_notification "Monitoring Deployed" "Prometheus, Grafana, and Alertmanager are running" "default" "chart_with_upwards_trend"
sleep 5

# Deploy network services
if [ "$SKIP_ADGUARD" != "true" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying AdGuard (DNS/ad-blocker)..."
    substitute_and_deploy "adguard" "stacks/adguard/adguard-stack.yml"
    send_notification "AdGuard Deployed" "DNS and ad-blocking active" "default" "shield"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Vaultwarden (password manager)..."
substitute_and_deploy "vaultwarden" "stacks/vaultwarden/vaultwarden-stack.yml"
send_notification "Vaultwarden Deployed" "Password manager is running" "default" "key"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Home Assistant..."
substitute_and_deploy "homeassistant" "stacks/homeassistant/homeassistant-stack.yml"
send_notification "Home Assistant Deployed" "Home automation is running" "default" "house"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deployment complete"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo ""
echo "Services deployed:"
echo "  ✓ Traefik       - http://traefik.local"
if [ "$SKIP_TAILSCALE" != "true" ]; then
    echo "  ✓ Tailscale     - Check admin console"
fi
echo "  ✓ Forgejo       - http://git.local"
echo "  ✓ Prometheus    - http://prometheus.local"
echo "  ✓ Alertmanager  - http://alertmanager.local"
echo "  ✓ Grafana       - http://grafana.local"
if [ "$SKIP_ADGUARD" != "true" ]; then
    echo "  ✓ AdGuard       - http://adguard.local"
fi
echo "  ✓ Vaultwarden   - https://vault.local (local HTTPS)"
echo "  ✓              - https://vault.${TAILSCALE_HOSTNAME}.${TAILNET_NAME} (remote)"
echo "  ✓ Home Assistant - http://ha.local (also :8123)"
echo "  ✓              - https://ha.${TAILSCALE_HOSTNAME}.${TAILNET_NAME} (remote)"
echo ""
echo "Check service status:"
echo "  docker service ls"
echo ""

# Send final success notification
send_notification "Deployment Complete" "All services deployed successfully! ✅" "default" "white_check_mark,rocket"
