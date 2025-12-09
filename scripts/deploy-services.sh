#!/bin/bash
# Deploy all Docker stacks with secret handling

set -e
cd "$(dirname "$0")/.."

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting deployment"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"

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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Traefik..."
docker stack deploy -c stacks/traefik/traefik-stack.yml traefik
sleep 5

if [ "$SKIP_TAILSCALE" != "true" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Tailscale..."
    docker stack deploy -c stacks/tailscale/tailscale-stack.yml tailscale
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Forgejo..."
docker stack deploy -c stacks/forgejo/forgejo-stack.yml forgejo

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Monitoring..."
docker stack deploy -c stacks/monitoring/monitoring-stack.yml monitoring

if [ "$SKIP_ADGUARD" != "true" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying AdGuard..."
    docker stack deploy -c stacks/adguard/adguard-stack.yml adguard
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Vaultwarden..."
docker stack deploy -c stacks/vaultwarden/vaultwarden-stack.yml vaultwarden

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deployment complete"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
