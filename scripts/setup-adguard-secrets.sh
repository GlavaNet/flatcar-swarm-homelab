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
echo "Deploy AdGuard with:"
echo "  docker stack deploy -c stacks/adguard/adguard-stack.yml adguard"
echo ""
echo "To update credentials in the future:"
echo "  ./scripts/setup-adguard-secrets.sh"
echo "  docker service update --force adguard_adguard"
