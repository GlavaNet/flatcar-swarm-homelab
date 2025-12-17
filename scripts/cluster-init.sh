#!/bin/bash
# cluster-init.sh - Run once on manager-1 after swarm bootstrap
# Updated to include git-poll GitOps automation

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
    echo "Generated SSH key on manager-1"
fi

# Distribute keys between all managers
for node in "${MANAGER_NODES[@]}"; do
    echo "Setting up keys with $node..."
    
    # Copy manager-1's key to other node
    cat ~/.ssh/id_rsa.pub | ssh core@$node "cat >> ~/.ssh/authorized_keys"
    
    # Generate key on remote node if missing and copy back
    ssh core@$node 'if [ ! -f ~/.ssh/id_rsa ]; then ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa; fi && cat ~/.ssh/id_rsa.pub' >> ~/.ssh/authorized_keys
done

# Copy keys between manager-2 and manager-3
ssh core@192.168.99.102 "cat ~/.ssh/id_rsa.pub" | ssh core@192.168.99.103 "cat >> ~/.ssh/authorized_keys"
ssh core@192.168.99.103 "cat ~/.ssh/id_rsa.pub" | ssh core@192.168.99.102 "cat >> ~/.ssh/authorized_keys"

# Remove duplicates on all nodes
for node in 192.168.99.101 "${MANAGER_NODES[@]}"; do
    if [ "$node" = "192.168.99.101" ]; then
        sort -u ~/.ssh/authorized_keys > /tmp/auth && mv /tmp/auth ~/.ssh/authorized_keys
    else
        ssh core@$node 'sort -u ~/.ssh/authorized_keys > /tmp/auth && mv /tmp/auth ~/.ssh/authorized_keys'
    fi
done

echo "✓ SSH keys distributed"

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
    echo "MinIO password: $MINIO_PASSWORD"
else
    MINIO_PASSWORD=$(cat ~/.minio-password)
fi

# Create MinIO stack file with password
sed "s/\${MINIO_PASSWORD}/$MINIO_PASSWORD/g" \
    stacks/minio/minio-stack.yml > /tmp/minio-deploy.yml

docker stack deploy -c /tmp/minio-deploy.yml minio
rm /tmp/minio-deploy.yml

echo "Waiting for MinIO to start..."
sleep 30

# Create backups bucket
docker run --rm --network host --entrypoint /bin/sh minio/mc:latest \
    -c "mc alias set homelab http://localhost:9000 minioadmin ${MINIO_PASSWORD} && mc mb homelab/backups"

echo "✓ MinIO deployed with backups bucket"

# ============================================================================
# Backup Services Installation
# ============================================================================

echo ""
echo "=== Installing backup services ==="

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

# ============================================================================
# Volume Replication Service Installation
# ============================================================================

echo ""
echo "=== Installing volume replication service ==="

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

# ============================================================================
# GitOps (git-poll) Service Installation
# ============================================================================

echo ""
echo "=== Installing GitOps automation (git-poll) ==="

# Install git-deploy-notify.sh script
sudo tee /opt/bin/git-deploy-notify.sh > /dev/null << 'EOFSCRIPT'
#!/bin/bash
# git-deploy-notify.sh - GitOps deployment wrapper with ntfy notifications

set -e

NTFY_URL="${NTFY_TOPIC_URL:-http://ntfy.local/swarm-alerts}"
REPO_DIR="/home/core/flatcar-swarm-homelab"
LOG_FILE="${REPO_DIR}/deploy.log"

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-rocket}"
    
    echo "[NTFY] $title: $message"
    
    if curl -sf -m 5 \
         -H "Title: ${title}" \
         -H "Priority: ${priority}" \
         -H "Tags: ${tags}" \
         -d "${message}" \
         "${NTFY_URL}" > /dev/null 2>&1; then
        echo "[NTFY] Notification sent successfully"
    else
        echo "[NTFY] Warning: Failed to send notification"
    fi
}

log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

log "=== GitOps Deployment Check Started ==="

mkdir -p "$(dirname "$LOG_FILE")"

if ! cd "$REPO_DIR"; then
    log "ERROR: Cannot access repository directory: $REPO_DIR"
    send_notification "GitOps: Critical Error" "Cannot access repository directory" "urgent" "x,file_folder"
    exit 1
fi

log "Repository directory: $(pwd)"
log "Fetching latest changes from origin/main..."

if ! git fetch origin; then
    log "ERROR: git fetch failed"
    send_notification "GitOps: Fetch Failed" "Unable to fetch from GitHub repository" "high" "x,git"
    exit 1
fi

log "Fetch completed successfully"

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

log "Local commit:  $LOCAL"
log "Remote commit: $REMOTE"

if [ "$LOCAL" = "$REMOTE" ]; then
    log "No new changes detected - exiting normally"
    exit 0
fi

log "New changes detected!"

send_notification "GitOps: Deployment Starting" "Pulling latest changes from repository..." "default" "rocket"

log "Resetting to origin/main..."
git reset --hard origin/main

CURRENT_HASH=$(git rev-parse --short HEAD)
COMMIT_MSG=$(git log -1 --pretty=%B | head -n1)

log "Updated to commit: $CURRENT_HASH"
log "Commit message: $COMMIT_MSG"

send_notification "GitOps: Repository Updated" "Commit: ${CURRENT_HASH} - ${COMMIT_MSG}" "default" "git"

DEPLOY_SCRIPT=""

if [ -f scripts/deploy-services-env.sh ]; then
    DEPLOY_SCRIPT="scripts/deploy-services-env.sh"
    log "Using environment-aware deployment script: $DEPLOY_SCRIPT"
    
    if [ ! -f .env.local ]; then
        log "WARNING: .env.local not found - deployment may fail"
        log "Create it from template: cp .env.template .env.local"
    fi
elif [ -f scripts/deploy-services.sh ]; then
    DEPLOY_SCRIPT="scripts/deploy-services.sh"
    log "Using basic deployment script: $DEPLOY_SCRIPT"
else
    log "ERROR: No deployment script found"
    send_notification "GitOps: Deployment Failed" "No deployment script found in repository" "urgent" "x,rocket"
    exit 1
fi

log "=== Starting Deployment ==="
log "Script: $DEPLOY_SCRIPT"
log "Time: $(date)"

set +e
bash "$DEPLOY_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
DEPLOY_EXIT_CODE=${PIPESTATUS[0]}
set -e

log "=== Deployment Finished ==="
log "Exit code: $DEPLOY_EXIT_CODE"

if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
    log "✓ Deployment completed successfully"
    send_notification "GitOps: Deployment Successful" "All services deployed successfully. Commit: ${CURRENT_HASH}" "default" "white_check_mark,rocket"
    exit 0
else
    log "✗ Deployment failed with exit code $DEPLOY_EXIT_CODE"
    log "Check logs for details: $LOG_FILE"
    send_notification "GitOps: Deployment Failed" "Deployment failed for commit ${CURRENT_HASH}. Check logs on manager-1." "urgent" "x,rocket"
    exit $DEPLOY_EXIT_CODE
fi
EOFSCRIPT

sudo chmod +x /opt/bin/git-deploy-notify.sh
echo "✓ Installed git-deploy-notify.sh"

# Install git-poll.service
sudo tee /etc/systemd/system/git-poll.service > /dev/null << 'EOFSERVICE'
[Unit]
Description=Pull git changes and deploy with notifications
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=core
Group=core
WorkingDirectory=/home/core/flatcar-swarm-homelab

EnvironmentFile=-/etc/environment
EnvironmentFile=-/home/core/flatcar-swarm-homelab/.env.local

ExecStart=/opt/bin/git-deploy-notify.sh

StandardOutput=journal
StandardError=journal
SyslogIdentifier=git-poll

TimeoutStartSec=1800
Restart=no

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

# ============================================================================
# Environment Configuration
# ============================================================================

# Create .env.local if it doesn't exist
if [ ! -f "$REPO_DIR/.env.local" ]; then
    echo ""
    echo "=== Environment Configuration Setup ==="
    echo ""
    
    if [ -f "$REPO_DIR/.env.template" ]; then
        cp "$REPO_DIR/.env.template" "$REPO_DIR/.env.local"
        
        echo "Created .env.local from template"
        echo ""
        echo "You need to configure your Tailscale settings:"
        echo "  nano $REPO_DIR/.env.local"
        echo ""
        echo "Required settings:"
        echo "  - TAILNET_NAME: Your Tailscale network name (e.g., tail1234a.ts.net)"
        echo "  - TAILSCALE_HOSTNAME: This node's hostname (e.g., swarm-manager-1)"
        echo ""
        echo "To find your Tailnet name after deploying Tailscale:"
        echo "  docker exec \$(docker ps -q -f name=tailscale) tailscale status | head -1"
        echo ""
    fi
fi

# ============================================================================
# Deploy Services
# ============================================================================

echo ""
echo "=== Deploying stacks ==="

# Only deploy if this is first run
if [ ! -f /home/core/.cluster-initialized ]; then
    if [ -f scripts/deploy-services-env.sh ]; then
        bash scripts/deploy-services-env.sh
    else
        bash scripts/deploy-services.sh
    fi
    
    touch /home/core/.cluster-initialized
    echo "Initial deployment complete"
else
    echo "Cluster already initialized, skipping stack deployment"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=== Cluster initialization complete ==="
echo ""
echo "Services installed:"
echo "  ✓ MinIO object storage"
echo "  ✓ Automated backups (daily at 2:00 AM)"
echo "  ✓ Volume replication (daily at 3:00 AM)"
echo "  ✓ GitOps automation (checks every 5 minutes)"
echo ""
echo "MinIO:"
echo "  Console: http://minio.local or http://192.168.99.101:9001"
echo "  Username: minioadmin"
echo "  Password: $(cat ~/.minio-password)"
echo ""
echo "GitOps (git-poll):"
echo "  Status: sudo systemctl status git-poll.timer"
echo "  Logs:   sudo journalctl -u git-poll.service -f"
echo "  Manual: sudo systemctl start git-poll.service"
echo ""
echo "Configuration:"
echo "  Edit .env.local: nano $REPO_DIR/.env.local"
echo ""
echo "Manual operations:"
echo "  Backup now:     sudo systemctl start minio-backup.service"
echo "  Replicate now:  sudo systemctl start volume-replication.service"
echo ""
