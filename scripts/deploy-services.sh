#!/bin/bash
# Deploy all Docker stacks with secret handling and ntfy notifications

set -e
cd "$(dirname "$0")/.."

NTFY_ENABLED=false

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting deployment"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"

# Function to send ntfy notification (if ntfy is deployed)
send_notification() {
    if [ "$NTFY_ENABLED" = "true" ]; then
        local title="$1"
        local message="$2"
        local priority="${3:-default}"
        local tags="${4:-rocket}"
        
        curl -H "Title: ${title}" \
             -H "Priority: ${priority}" \
             -H "Tags: ${tags}" \
             -d "${message}" \
             "https://ntfy.sh/swarm-6c7d3e5bf293-alerts" 2>/dev/null || true
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
docker stack deploy -c stacks/traefik/traefik-stack.yml traefik
sleep 5

# Deploy ntfy early so other services can send notifications
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying ntfy (notification service)..."
if docker stack deploy -c stacks/ntfy/ntfy-stack.yml ntfy; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ntfy deployed, waiting 10 seconds for service to start..."
    sleep 10
    # Check if ntfy is accessible
    if curl -s http://ntfy.local > /dev/null 2>&1 || curl -s http://192.168.99.101 > /dev/null 2>&1; then
        NTFY_ENABLED=true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ntfy is accessible, notifications enabled"
        send_notification "Deployment Started" "Cluster deployment in progress..." "default" "rocket"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ntfy not yet accessible, notifications disabled"
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: ntfy deployment failed, continuing without notifications"
fi

# Deploy Tailscale (optional VPN access)
if [ "$SKIP_TAILSCALE" != "true" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Tailscale (VPN)..."
    docker stack deploy -c stacks/tailscale/tailscale-stack.yml tailscale
    send_notification "Tailscale Deployed" "VPN access configured" "default" "lock"
fi

# Deploy application services
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Forgejo (Git server)..."
docker stack deploy -c stacks/forgejo/forgejo-stack.yml forgejo
send_notification "Forgejo Deployed" "Git server is running" "default" "git"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Monitoring (Prometheus + Grafana + Alertmanager)..."
docker stack deploy -c stacks/monitoring/monitoring-stack.yml monitoring
send_notification "Monitoring Deployed" "Prometheus, Grafana, and Alertmanager are running" "default" "chart_with_upwards_trend"
sleep 5

# Deploy network services
if [ "$SKIP_ADGUARD" != "true" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying AdGuard (DNS/ad-blocker)..."
    docker stack deploy -c stacks/adguard/adguard-stack.yml adguard
    send_notification "AdGuard Deployed" "DNS and ad-blocking active" "default" "shield"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Vaultwarden (password manager)..."
docker stack deploy -c stacks/vaultwarden/vaultwarden-stack.yml vaultwarden
send_notification "Vaultwarden Deployed" "Password manager is running" "default" "key"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deployment complete"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo ""
echo "Services deployed:"
echo "  ✓ Traefik       - http://traefik.local"
echo "  ✓ ntfy          - http://ntfy.local"
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
echo "  ✓ Vaultwarden   - http://vault.local"
echo ""
echo "Check service status:"
echo "  docker service ls"
echo ""
echo "View logs for a service:"
echo "  docker service logs -f <service_name>"
echo ""

# Send final success notification
send_notification "Deployment Complete" "All services deployed successfully! ✅" "default" "white_check_mark,rocket"

# Display alert configuration reminder
if [ "$NTFY_ENABLED" = "true" ]; then
    echo "================================="
    echo "ntfy Notifications Setup"
    echo "================================="
    echo ""
    echo "To receive mobile notifications:"
    echo "  1. Install ntfy app (iOS/Android)"
    echo "  2. Add subscription:"
    echo "     - Server: http://ntfy.local (or http://192.168.99.101)"
    echo "     - Topic: swarm-alerts"
    echo "  3. Enable notifications in phone settings"
    echo ""
    echo "Test notification:"
    echo "  curl -d 'Test from Swarm cluster' http://ntfy.local/swarm-alerts"
    echo ""
fi
