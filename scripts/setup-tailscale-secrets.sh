#!/bin/bash
# Generate Tailscale auth key secret for Docker Swarm

set -e

echo "=== Tailscale Subnet Router & Exit Node Setup (Multi-Node) ==="
echo ""
echo "Before running this script, you need to generate an auth key:"
echo ""
echo "1. Go to: https://login.tailscale.com/admin/settings/keys"
echo "2. Click 'Generate auth key'"
echo "3. IMPORTANT Settings for multi-node:"
echo "   ✓ Reusable: YES (REQUIRED - will create 3 nodes)"
echo "   ✓ Ephemeral: NO (keeps nodes in network)"
echo "   ✓ Expiration: 90 days or longer"
echo "   ✓ Pre-authorized: YES (avoids manual approval for each node)"
echo "   ✓ Tags: Add 'tag:homelab' (recommended for ACLs)"
echo ""
echo "This will create 3 separate Tailscale nodes:"
echo "  - swarm-manager-1 (192.168.99.101)"
echo "  - swarm-manager-2 (192.168.99.102)"
echo "  - swarm-manager-3 (192.168.99.103)"
echo ""
read -p "Press Enter when you have your REUSABLE auth key ready..."
echo ""

# Prompt for auth key
read -sp "Enter Tailscale auth key (must be reusable): " TAILSCALE_AUTH_KEY
echo ""

if [ -z "$TAILSCALE_AUTH_KEY" ]; then
    echo "Error: Auth key cannot be empty"
    exit 1
fi

# Validate format (starts with tskey-)
if [[ ! "$TAILSCALE_AUTH_KEY" =~ ^tskey- ]]; then
    echo "Warning: Auth key should start with 'tskey-'. Are you sure this is correct?"
    read -p "Continue anyway? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        exit 1
    fi
fi

# Remove existing secret if it exists
docker secret rm tailscale_auth_key 2>/dev/null && echo "Removed old tailscale_auth_key secret" || true

# Create Docker secret
echo "$TAILSCALE_AUTH_KEY" | docker secret create tailscale_auth_key -

echo ""
echo "✓ Tailscale auth key stored in Docker Swarm secret"
echo ""
echo "Next steps:"
echo ""
echo "1. Deploy Tailscale to all managers:"
echo "   docker stack deploy -c stacks/tailscale/tailscale-stack.yml tailscale"
echo ""
echo "2. Check deployment:"
echo "   docker service ls | grep tailscale"
echo "   docker service ps tailscale_router"
echo ""
echo "3. View logs for each instance:"
echo "   docker service logs tailscale_router"
echo ""
echo "4. In Tailscale admin console (https://login.tailscale.com/admin/machines):"
echo "   You should see 3 new devices:"
echo "   - swarm-manager-1"
echo "   - swarm-manager-2"
echo "   - swarm-manager-3"
echo ""
echo "5. Enable routes for ALL THREE nodes:"
echo "   For each node, click '...' menu → Edit route settings:"
echo "     ✓ Enable 'Subnet routes' for 192.168.99.0/24"
echo "     ✓ Enable 'Use as exit node'"
echo ""
echo "6. Tailscale will automatically load-balance between the 3 exit nodes"
echo ""
