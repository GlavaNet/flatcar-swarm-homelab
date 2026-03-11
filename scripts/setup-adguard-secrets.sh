#!/bin/bash
# Generate AdGuard secrets for Docker Swarm

set -e

echo "=== AdGuard Home Secret Setup ==="
echo ""

# Prompt for credentials
read -p "Enter AdGuard admin username [admin]: " ADGUARD_USER
ADGUARD_USER=${ADGUARD_USER:-admin}

read -sp "Enter AdGuard admin password: " ADGUARD_PASSWORD
echo ""

if [ -z "$ADGUARD_PASSWORD" ]; then
    echo "Error: Password cannot be empty"
    exit 1
fi

# Confirm password
read -sp "Confirm password: " ADGUARD_PASSWORD_CONFIRM
echo ""

if [ "$ADGUARD_PASSWORD" != "$ADGUARD_PASSWORD_CONFIRM" ]; then
    echo "Error: Passwords do not match"
    exit 1
fi

# Generate bcrypt hash
echo "Generating password hash..."
PASSWORD_HASH=$(docker run --rm httpd:2.4-alpine htpasswd -nbB "$ADGUARD_USER" "$ADGUARD_PASSWORD" | cut -d ":" -f 2)

# Remove existing secrets if they exist
docker secret rm adguard_username 2>/dev/null && echo "Removed old adguard_username secret" || true
docker secret rm adguard_password_hash 2>/dev/null && echo "Removed old adguard_password_hash secret" || true

# Create Docker secrets
echo "$ADGUARD_USER" | docker secret create adguard_username -
echo "$PASSWORD_HASH" | docker secret create adguard_password_hash -

echo ""
echo "✓ Secrets created successfully"
echo ""
echo "Username: $ADGUARD_USER"
echo "Password: (hidden)"
echo ""
echo "Secrets stored in Docker Swarm:"
echo "  - adguard_username"
echo "  - adguard_password_hash"
echo ""

# ===========================================================================
# Disable systemd-resolved stub listener on all manager nodes
# AdGuard requires exclusive use of port 53; the resolved stub listener
# conflicts with it and will cause the container to fail to start.
# ===========================================================================

echo "=== Preparing nodes for AdGuard (port 53) ==="
echo ""

# Discover manager IPs from swarm
MANAGER_IPS=$(docker node ls --filter role=manager --format '{{.Hostname}}' | \
    xargs -I{} docker node inspect {} --format '{{range .Status}}{{.Addr}}{{end}}' 2>/dev/null) || true

if [ -z "$MANAGER_IPS" ]; then
    echo "⚠️  Could not discover manager nodes from swarm."
    echo "   Manually disable systemd-resolved stub listener on all managers:"
    echo "     sudo mkdir -p /etc/systemd/resolved.conf.d"
    echo "     echo -e '[Resolve]\nDNSStubListener=no' | sudo tee /etc/systemd/resolved.conf.d/no-stub.conf"
    echo "     sudo systemctl restart systemd-resolved"
else
    for ip in $MANAGER_IPS; do
        echo "Disabling resolved stub listener on $ip..."
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 core@"$ip" \
            'sudo mkdir -p /etc/systemd/resolved.conf.d && \
             echo -e "[Resolve]\nDNSStubListener=no" | \
             sudo tee /etc/systemd/resolved.conf.d/no-stub.conf > /dev/null && \
             sudo systemctl restart systemd-resolved && \
             echo "  ✓ Done"' || echo "  ⚠️  Could not reach $ip — apply manually"
    done
fi

echo ""
echo "Deploy AdGuard with:"
echo "  docker stack deploy -c stacks/adguard/adguard-stack.yml adguard"
echo ""
echo "To update credentials in the future:"
echo "  ./scripts/setup-adguard-secrets.sh"
echo "  docker service update --force adguard_adguard"
