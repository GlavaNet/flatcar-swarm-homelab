#!/bin/bash
set -e
cd "$(dirname "$0")/.."

echo "Deploying stacks..."
docker stack deploy -c stacks/traefik/traefik-stack.yml traefik
docker stack deploy -c stacks/monitoring/monitoring-stack.yml monitoring
docker stack deploy -c stacks/adguard/adguard-stack.yml adguard
docker stack deploy -c stacks/vaultwarden/vaultwarden-stack.yml vaultwarden
echo "Deployment complete"
