#!/bin/bash
# cluster-init.sh - Run once on manager-1 after swarm bootstrap
# Updated to include properly configured git-poll GitOps automation

set -e

REPO_URL="https://github.com/GlavaNet/flatcar-swarm-homelab.git"
REPO_DIR="/home/core/flatcar-swarm-homelab"
MANAGER_NODES=("192.168.99.102" "192.168.99.103")

echo "=== Flatcar Swarm Cluster Initialization ==="
echo ""

# ============================================================================
# Repository Setup
# ============================================================================

echo "Cloning repository..."
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
    echo "✓ Repository cloned"
else
    echo "✓ Repository already exists"
    cd "$REPO_DIR"
    git fetch origin
    git reset --hard origin/main
fi

cd "$REPO_DIR"

# ============================================================================
# SSH Key Distribution (for replication and backups)
# ============================================================================

echo ""
echo "=== Setting up SSH keys between nodes ==="

# Generate SSH key on manager-1 if missing
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    echo "✓ Generated SSH key on manager-1"
fi

MANAGER1_PUBKEY=$(cat ~/.ssh/id_rsa.pub)

# For each remote manager, perform the entire key exchange in a SINGLE ssh session
# to avoid triggering account lockout from rapid reconnects.
# Each node: generates its own key if missing, accepts manager-1's key, returns its pubkey.
declare -A REMOTE_PUBKEYS

for node in "${MANAGER_NODES[@]}"; do
    echo "Exchanging keys with $node..."

    REMOTE_PUBKEYS[$node]=$(ssh -o StrictHostKeyChecking=no core@$node bash << ENDSSH
# Generate key if missing
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
fi

# Add manager-1's key if not already present
if ! grep -qF "${MANAGER1_PUBKEY}" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "${MANAGER1_PUBKEY}" >> ~/.ssh/authorized_keys
fi

# Return this node's public key
cat ~/.ssh/id_rsa.pub
ENDSSH
    )
    echo "  ✓ Got key from $node"
done

# Add all remote keys to manager-1's authorized_keys
for node in "${MANAGER_NODES[@]}"; do
    if ! grep -qF "${REMOTE_PUBKEYS[$node]}" ~/.ssh/authorized_keys 2>/dev/null; then
        echo "${REMOTE_PUBKEYS[$node]}" >> ~/.ssh/authorized_keys
    fi
done

# Build the complete deduplicated authorized_keys on manager-1,
# then push it to each remote node in a single SSH session.
# This avoids any cross-node SSH (manager-2 -> manager-3) which was the main lockout trigger.
ALL_KEYS=$(sort -u ~/.ssh/authorized_keys)

for node in "${MANAGER_NODES[@]}"; do
    ssh -o StrictHostKeyChecking=no core@$node bash << ENDSSH
printf '%s\n' "${ALL_KEYS}" > /tmp/auth_keys_new
# Merge with any keys on the remote not already captured
cat ~/.ssh/authorized_keys >> /tmp/auth_keys_new 2>/dev/null || true
sort -u /tmp/auth_keys_new > ~/.ssh/authorized_keys
rm /tmp/auth_keys_new
ENDSSH
    echo "  ✓ Keys synced to $node"
done

# Deduplicate manager-1's own authorized_keys
sort -u ~/.ssh/authorized_keys > /tmp/auth && mv /tmp/auth ~/.ssh/authorized_keys

echo "✓ SSH keys distributed"

# ============================================================================
# ntfy Configuration
# ============================================================================

echo ""
echo "=== Configuring ntfy Notifications ==="

if [ ! -f /home/core/.ntfy-url ]; then
    echo "Generating unique ntfy topic..."

    RANDOM_ID=$(openssl rand -hex 6)
    NTFY_URL="https://ntfy.sh/flatcar-swarm-${RANDOM_ID}"

    echo "$NTFY_URL" > /home/core/.ntfy-url
    chmod 600 /home/core/.ntfy-url

    export NTFY_TOPIC_URL="$NTFY_URL"

    echo "✓ ntfy configured: $NTFY_URL"
    echo ""
    echo "📱 To receive notifications on your phone:"
    echo "   1. Install 'ntfy' app from App Store or Play Store"
    echo "   2. Subscribe to topic: flatcar-swarm-${RANDOM_ID}"
    echo "   3. You'll receive alerts for deployments, errors, and cluster events"
    echo ""
else
    export NTFY_TOPIC_URL=$(cat /home/core/.ntfy-url)
    echo "✓ ntfy already configured: $NTFY_TOPIC_URL"
fi

# ============================================================================
# TLS Certificate Generation
# ============================================================================

echo ""
echo "=== Generating TLS certificates ==="

if [ -f scripts/generate-local-certs.sh ]; then
    bash scripts/generate-local-certs.sh
else
    mkdir -p /home/core/certs
    if [ ! -f /home/core/certs/vault.crt ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /home/core/certs/vault.key \
            -out /home/core/certs/vault.crt \
            -subj "/CN=vault.local" \
            -addext "subjectAltName=DNS:vault.local" \
            2>/dev/null
        echo "✓ Generated self-signed certificate for vault.local"
    fi
fi

# ============================================================================
# MinIO Deployment
# ============================================================================

echo ""
echo "=== Deploying MinIO ==="

# Generate MinIO password
if [ ! -f ~/.minio-password ]; then
    MINIO_PASSWORD=$(openssl rand -base64 24)
    echo "$MINIO_PASSWORD" > ~/.minio-password
    chmod 600 ~/.minio-password
    echo "✓ MinIO password generated: $MINIO_PASSWORD"
else
    MINIO_PASSWORD=$(cat ~/.minio-password)
    echo "✓ Using existing MinIO password"
fi

# Deploy MinIO
if [ -f stacks/minio/minio-stack.yml ]; then
    sed "s/\${MINIO_PASSWORD}/$MINIO_PASSWORD/g" \
        stacks/minio/minio-stack.yml > /tmp/minio-deploy.yml

    docker stack deploy -c /tmp/minio-deploy.yml minio
    rm /tmp/minio-deploy.yml

    echo "Waiting for MinIO to start..."
    sleep 30

    # Create backups bucket
    docker run --rm --network host --entrypoint /bin/sh minio/mc:latest \
        -c "mc alias set homelab http://localhost:9000 minioadmin ${MINIO_PASSWORD} && mc mb homelab/backups --ignore-existing" 2>/dev/null || echo "Bucket may already exist"

    echo "✓ MinIO deployed with backups bucket"
fi

# ============================================================================
# Backup Services Installation
# ============================================================================

echo ""
echo "=== Installing backup services ==="

if [ -f scripts/backup-to-minio.sh ]; then
    # Copy backup script
    sudo cp scripts/backup-to-minio.sh /opt/bin/
    sudo chmod +x /opt/bin/backup-to-minio.sh

    # Create service
    sudo tee /etc/systemd/system/minio-backup.service > /dev/null << 'EOF'
[Unit]
Description=Backup volumes to MinIO
After=docker.service

[Service]
Type=oneshot
User=core
Group=core
ExecStart=/opt/bin/backup-to-minio.sh
StandardOutput=journal
StandardError=journal
EOF

    # Create timer
    sudo tee /etc/systemd/system/minio-backup.timer > /dev/null << 'EOF'
[Unit]
Description=Daily MinIO backup

[Timer]
OnCalendar=02:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable minio-backup.timer
    sudo systemctl start minio-backup.timer

    echo "✓ MinIO backup service installed"
fi

# ============================================================================
# Volume Replication Service Installation
# ============================================================================

echo ""
echo "=== Installing volume replication service ==="

if [ -f scripts/replicate-volumes.sh ]; then
    sudo cp scripts/replicate-volumes.sh /opt/bin/
    sudo chmod +x /opt/bin/replicate-volumes.sh

    sudo tee /etc/systemd/system/volume-replication.service > /dev/null << 'EOF'
[Unit]
Description=Replicate Docker volumes to backup managers
After=docker.service

[Service]
Type=oneshot
User=core
Group=core
ExecStart=/opt/bin/replicate-volumes.sh
StandardOutput=journal
StandardError=journal
EOF

    sudo tee /etc/systemd/system/volume-replication.timer > /dev/null << 'EOF'
[Unit]
Description=Daily volume replication

[Timer]
OnCalendar=03:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable volume-replication.timer
    sudo systemctl start volume-replication.timer

    echo "✓ Volume replication service installed"
fi

# ============================================================================
# GitOps (git-poll) Service Installation
# ============================================================================

echo ""
echo "=== Installing GitOps automation (git-poll) ==="

# Install improved git-deploy-notify.sh script
sudo tee /opt/bin/git-deploy-notify.sh > /dev/null << 'EOFSCRIPT'
#!/bin/bash
# git-deploy-notify.sh - GitOps deployment with proper error handling

set -e

REPO_DIR="/home/core/flatcar-swarm-homelab"
LOG_FILE="${REPO_DIR}/deploy.log"

# Get NTFY_TOPIC_URL from multiple sources
if [ -z "$NTFY_TOPIC_URL" ]; then
    [ -f "${REPO_DIR}/.env.local" ] && source "${REPO_DIR}/.env.local"
fi

if [ -z "$NTFY_TOPIC_URL" ]; then
    [ -f "$HOME/.ntfy-url" ] && NTFY_TOPIC_URL=$(cat "$HOME/.ntfy-url")
fi

if [ -z "$NTFY_TOPIC_URL" ]; then
    NTFY_TOPIC_URL="http://ntfy.local/swarm-alerts"
fi

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-rocket}"

    echo "[NTFY] $title: $message"

    [ -z "$NTFY_TOPIC_URL" ] || [ "$NTFY_TOPIC_URL" = "disabled" ] && return 0

    timeout 10 curl -sf \
         -H "Title: ${title}" \
         -H "Priority: ${priority}" \
         -H "Tags: ${tags}" \
         -d "${message}" \
         "${NTFY_TOPIC_URL}" > /dev/null 2>&1 || echo "[NTFY] ⚠️ Send failed"
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== GitOps Check Started ==="
log "NTFY: ${NTFY_TOPIC_URL}"

mkdir -p "$(dirname "$LOG_FILE")"

cd "$REPO_DIR" || {
    log "ERROR: Cannot access $REPO_DIR"
    send_notification "GitOps: Critical Error" "Cannot access repository" "urgent" "x,file_folder"
    exit 1
}

log "Testing GitHub connectivity..."
timeout 5 curl -sf https://github.com > /dev/null 2>&1 && log "✓ GitHub reachable" || log "⚠️ GitHub unreachable"

log "Fetching from origin..."
if ! timeout 30 git fetch origin 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: git fetch failed"
    send_notification "GitOps: Fetch Failed" "Cannot fetch from GitHub" "high" "x,git"
    exit 1
fi

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

log "Local:  $LOCAL"
log "Remote: $REMOTE"

[ "$LOCAL" = "$REMOTE" ] && { log "✓ No changes"; exit 0; }

log "✓ New changes detected"

CURRENT_HASH=$(git rev-parse --short origin/main)
COMMIT_MSG=$(git log origin/main -1 --pretty=%B | head -n1)

send_notification "GitOps: Deploying" "Pulling: ${COMMIT_MSG}" "default" "rocket"

git reset --hard origin/main 2>&1 | tee -a "$LOG_FILE" || {
    log "ERROR: git reset failed"
    send_notification "GitOps: Update Failed" "Failed to update repository" "urgent" "x,git"
    exit 1
}

send_notification "GitOps: Updated" "Commit: ${CURRENT_HASH}" "default" "git"

DEPLOY_SCRIPT="scripts/deploy-services.sh"

if [ ! -f "$DEPLOY_SCRIPT" ]; then
    log "ERROR: Deploy script not found"
    send_notification "GitOps: No Deploy Script" "Script not found" "urgent" "x,rocket"
    exit 1
fi

log "=== Deploying ==="
[ -f .env.local ] && source .env.local

set +e
bash "$DEPLOY_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

log "=== Finished (exit $EXIT_CODE) ==="

if [ $EXIT_CODE -eq 0 ]; then
    log "✓ Success"
    send_notification "GitOps: Success" "Commit ${CURRENT_HASH} deployed" "default" "white_check_mark,rocket"
else
    log "✗ Failed"
    send_notification "GitOps: Failed" "Deployment failed, check logs" "urgent" "x,rocket"
fi

exit $EXIT_CODE
EOFSCRIPT

sudo chmod +x /opt/bin/git-deploy-notify.sh
echo "✓ Installed git-deploy-notify.sh"

# Install git-poll.service with proper environment loading
sudo tee /etc/systemd/system/git-poll.service > /dev/null << 'EOFSERVICE'
[Unit]
Description=GitOps deployment with notifications
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=core
Group=core
WorkingDirectory=/home/core/flatcar-swarm-homelab

# Load environment from multiple sources
EnvironmentFile=-/etc/environment
EnvironmentFile=-/home/core/flatcar-swarm-homelab/.env.local

# Also set NTFY_TOPIC_URL from ~/.ntfy-url if it exists
ExecStartPre=/bin/sh -c 'if [ -f /home/core/.ntfy-url ]; then echo "NTFY_TOPIC_URL=$(cat /home/core/.ntfy-url)" > /tmp/ntfy-env; fi'
EnvironmentFile=-/tmp/ntfy-env

ExecStart=/opt/bin/git-deploy-notify.sh

StandardOutput=journal
StandardError=journal
SyslogIdentifier=git-poll

TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOFSERVICE

echo "✓ Installed git-poll.service"

# Install git-poll.timer
sudo tee /etc/systemd/system/git-poll.timer > /dev/null << 'EOFTIMER'
[Unit]
Description=Check for git changes every 5 minutes
Requires=git-poll.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=git-poll.service
Persistent=false

[Install]
WantedBy=timers.target
EOFTIMER

echo "✓ Installed git-poll.timer"

# Enable and start git-poll
sudo systemctl daemon-reload
sudo systemctl enable git-poll.timer
sudo systemctl start git-poll.timer

echo "✓ GitOps automation enabled"

# Send test notification
if [ -n "$NTFY_TOPIC_URL" ]; then
    echo "Sending test notification..."
    curl -sf -m 5 \
        -H "Title: GitOps: Cluster Initialized" \
        -H "Priority: default" \
        -H "Tags: white_check_mark,rocket" \
        -d "Flatcar Swarm cluster initialization complete. GitOps automation is now active." \
        "$NTFY_TOPIC_URL" > /dev/null 2>&1 && echo "✓ Test notification sent" || echo "⚠️ Could not send test notification"
fi

# ============================================================================
# Environment Configuration
# ============================================================================

echo ""
echo "=== Environment Configuration Setup ==="

# Create .env.local if it doesn't exist
if [ ! -f "$REPO_DIR/.env.local" ]; then
    if [ -f "$REPO_DIR/.env.template" ]; then
        cp "$REPO_DIR/.env.template" "$REPO_DIR/.env.local"
        echo "✓ Created .env.local from template"
        echo ""
        echo "⚠️  You need to configure your Tailscale settings:"
        echo "   nano $REPO_DIR/.env.local"
        echo ""
        echo "Required settings:"
        echo "  - TAILNET_NAME: Your Tailscale network name (e.g., tail1234a.ts.net)"
        echo "  - TAILSCALE_HOSTNAME: This node's hostname (e.g., swarm-manager-1)"
    fi
fi

# ============================================================================
# Deploy Services
# ============================================================================

echo ""
echo "=== Deploying stacks ==="

# Only deploy if this is first run
if [ ! -f /home/core/.cluster-initialized ]; then
    if [ -f scripts/deploy-services.sh ]; then
        bash scripts/deploy-services.sh
    fi

    touch /home/core/.cluster-initialized
    echo "✓ Initial deployment complete"
else
    echo "✓ Cluster already initialized, skipping stack deployment"
    echo "  Run manually if needed: bash scripts/deploy-services.sh"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=========================================="
echo "  Cluster Initialization Complete!"
echo "=========================================="
echo ""
echo "✓ Services installed:"
echo "  • MinIO object storage"
echo "  • Automated backups (daily at 2:00 AM)"
echo "  • Volume replication (daily at 3:00 AM)"
echo "  • GitOps automation (checks every 5 minutes)"
echo ""
echo "📦 MinIO:"
echo "  Console: http://minio.local or http://192.168.99.101:9001"
echo "  Username: minioadmin"
echo "  Password: $(cat ~/.minio-password 2>/dev/null || echo 'not set')"
echo ""
echo "🔄 GitOps (git-poll):"
echo "  Status: sudo systemctl status git-poll.timer"
echo "  Logs:   sudo journalctl -u git-poll.service -f"
echo "  Manual: sudo systemctl start git-poll.service"
echo ""
echo "📱 Notifications:"
echo "  Topic URL: $(cat ~/.ntfy-url 2>/dev/null || echo 'not configured')"
echo "  Install 'ntfy' app and subscribe to topic to receive alerts"
echo ""
echo "⚙️  Configuration:"
echo "  Edit .env.local: nano $REPO_DIR/.env.local"
echo "  View ntfy topic:  cat ~/.ntfy-url"
echo ""
echo "🛠️  Manual operations:"
echo "  Backup now:     sudo systemctl start minio-backup.service"
echo "  Replicate now:  sudo systemctl start volume-replication.service"
echo "  Deploy now:     sudo systemctl start git-poll.service"
echo ""
echo "Next steps:"
echo "  1. Configure Tailscale in .env.local"
echo "  2. Install ntfy app on your phone"
echo "  3. Make a test commit to trigger GitOps"
echo "  4. Monitor: sudo journalctl -u git-poll.service -f"
echo ""
