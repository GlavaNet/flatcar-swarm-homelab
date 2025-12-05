#!/bin/bash
# cluster-init.sh - Run once on manager-1 after swarm bootstrap

set -e

REPO_URL="https://github.com/GlavaNet/flatcar-swarm-homelab.git"
REPO_DIR="/home/core/flatcar-swarm-homelab"

echo "Cloning repository..."
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
fi

echo "Generating TLS certificates..."
mkdir -p /home/core/certs
if [ ! -f /home/core/certs/vault.crt ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /home/core/certs/vault.key \
        -out /home/core/certs/vault.crt \
        -subj "/CN=vault.local" 2>/dev/null
fi

cat > /home/core/certs/dynamic.yml << 'EOF'
tls:
  certificates:
    - certFile: /certs/vault.crt
      keyFile: /certs/vault.key
EOF

echo "Deploying stacks..."
cd "$REPO_DIR"
bash scripts/deploy-services.sh

echo "Cluster initialization complete"
