#!/bin/bash
# Deploy all Docker stacks

set -e
cd "$(dirname "$0")/.."

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting deployment"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Current commit: $(git rev-parse --short HEAD)"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Commit message: $(git log -1 --pretty=%B | head -n1)"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Traefik..."
docker stack deploy -c stacks/traefik/traefik-stack.yml traefik
sleep 5

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Forgejo..."
docker stack deploy -c stacks/forgejo/forgejo-stack.yml forgejo

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Monitoring..."
docker stack deploy -c stacks/monitoring/monitoring-stack.yml monitoring

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying AdGuard..."
docker stack deploy -c stacks/adguard/adguard-stack.yml adguard

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Vaultwarden..."
docker stack deploy -c stacks/vaultwarden/vaultwarden-stack.yml vaultwarden

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deployment complete"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================"
