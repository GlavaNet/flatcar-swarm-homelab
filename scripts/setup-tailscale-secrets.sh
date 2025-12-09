#!/bin/bash
# Generate Tailscale auth key secret for Docker Swarm

set -e

echo "=== Tailscale Subnet Router & Exit Node Setup ==="
echo ""
echo "Before running this script, you need to generate an auth key:"
echo ""
echo "1. Go to: https://login.tailscale.com/admin/settings/keys"
echo "2. Click 'Generate auth key'"
echo "3. Settings:"
echo "   ✓ Reusable: YES (so you can redeploy)"
echo "   ✓ Ephemeral: NO (keeps node in network)"
echo "   ✓ Expiration: 90 days or longer"
echo "   ✓ Pre-authorized: YES (optional, avoids manual approval)"
echo "   ✓ Tags: Add 'tag:homelab' or 'tag:router' if using ACLs"
echo ""
read -p "Press Enter when you have your auth key ready..."
echo ""

# Prompt for auth key
read -sp "Enter Tailscale auth key: " TAILSCALE_AUTH_KEY
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
echo "1. Deploy Tailscale:"
echo "   docker stack deploy -c stacks/tailscale/tailscale-stack.yml tailscale"
echo ""
echo "2. Check logs:"
echo "   docker service logs -f tailscale_router"
echo ""
echo "3. In Tailscale admin console (https://login.tailscale.com/admin/machines):"
echo "   - Find your new device (swarm-manager-1)"
echo "   - Click '...' menu"
echo "   - Edit route settings:"
echo "     ✓ Enable 'Subnet routes' for 192.168.99.0/24"
echo "     ✓ Enable 'Use as exit node'"
echo ""
echo "4. Test connectivity:"
echo "   - From any Tailscale device: ping 192.168.99.101"
echo "   - Enable exit node in Tailscale app to route all traffic"
echo ""
