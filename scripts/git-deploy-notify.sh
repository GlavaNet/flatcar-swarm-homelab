#!/bin/bash
# git-deploy-notify.sh - GitOps deployment wrapper with ntfy notifications
#
# This script:
# 1. Checks for new commits from GitHub
# 2. Pulls changes if found
# 3. Deploys updated stacks
# 4. Sends notifications via ntfy
# 5. Logs everything to both journal and file
#
# Exit codes:
#   0 = Success (either no changes or deployment succeeded)
#   1 = Failure (deployment failed)

set -e  # Exit on any error

# Configuration
NTFY_URL="${NTFY_TOPIC_URL:-http://ntfy.local/swarm-alerts}"
REPO_DIR="/home/core/flatcar-swarm-homelab"
LOG_FILE="${REPO_DIR}/deploy.log"

# ============================================================================
# Functions
# ============================================================================

# Send notification to ntfy
# Args: title, message, priority, tags
send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-rocket}"
    
    # Always log to journal so it appears in journalctl
    echo "[NTFY] $title: $message"
    
    # Try to send to ntfy, but don't fail if it's unavailable
    if curl -sf -m 5 \
         -H "Title: ${title}" \
         -H "Priority: ${priority}" \
         -H "Tags: ${tags}" \
         -d "${message}" \
         "${NTFY_URL}" > /dev/null 2>&1; then
        echo "[NTFY] Notification sent successfully"
    else
        echo "[NTFY] Warning: Failed to send notification (ntfy may be unavailable)"
        # Don't exit - notifications are nice-to-have, not critical
    fi
}

# Log to both journal and file
log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

# ============================================================================
# Main Script
# ============================================================================

log "=== GitOps Deployment Check Started ==="

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Change to repository directory
if ! cd "$REPO_DIR"; then
    log "ERROR: Cannot access repository directory: $REPO_DIR"
    send_notification \
        "GitOps: Critical Error" \
        "Cannot access repository directory" \
        "urgent" \
        "x,file_folder"
    exit 1
fi

log "Repository directory: $(pwd)"

# ============================================================================
# Step 1: Fetch latest changes from GitHub
# ============================================================================

log "Fetching latest changes from origin/main..."

if ! git fetch origin; then
    log "ERROR: git fetch failed"
    send_notification \
        "GitOps: Fetch Failed" \
        "Unable to fetch from GitHub repository" \
        "high" \
        "x,git"
    exit 1
fi

log "Fetch completed successfully"

# ============================================================================
# Step 2: Check if there are new commits
# ============================================================================

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

log "Local commit:  $LOCAL"
log "Remote commit: $REMOTE"

if [ "$LOCAL" = "$REMOTE" ]; then
    log "No new changes detected - exiting normally"
    exit 0
fi

log "New changes detected!"

# ============================================================================
# Step 3: Pull changes and notify
# ============================================================================

send_notification \
    "GitOps: Deployment Starting" \
    "Pulling latest changes from repository..." \
    "default" \
    "rocket"

log "Resetting to origin/main..."
git reset --hard origin/main

# Get commit information
CURRENT_HASH=$(git rev-parse --short HEAD)
COMMIT_MSG=$(git log -1 --pretty=%B | head -n1)

log "Updated to commit: $CURRENT_HASH"
log "Commit message: $COMMIT_MSG"

send_notification \
    "GitOps: Repository Updated" \
    "Commit: ${CURRENT_HASH} - ${COMMIT_MSG}" \
    "default" \
    "git"

# ============================================================================
# Step 4: Determine which deployment script to use
# ============================================================================

DEPLOY_SCRIPT=""

# Prefer deploy-services-env.sh (environment variable version)
if [ -f scripts/deploy-services-env.sh ]; then
    DEPLOY_SCRIPT="scripts/deploy-services-env.sh"
    log "Using environment-aware deployment script: $DEPLOY_SCRIPT"
    
    # Check if .env.local exists
    if [ ! -f .env.local ]; then
        log "WARNING: .env.local not found - deployment may fail"
        log "Create it from template: cp .env.template .env.local"
    fi

# Fall back to deploy-services.sh (basic version)
elif [ -f scripts/deploy-services.sh ]; then
    DEPLOY_SCRIPT="scripts/deploy-services.sh"
    log "Using basic deployment script: $DEPLOY_SCRIPT"

# No deployment script found
else
    log "ERROR: No deployment script found"
    log "Looked for:"
    log "  - scripts/deploy-services-env.sh"
    log "  - scripts/deploy-services.sh"
    
    send_notification \
        "GitOps: Deployment Failed" \
        "No deployment script found in repository" \
        "urgent" \
        "x,rocket"
    exit 1
fi

# ============================================================================
# Step 5: Execute deployment
# ============================================================================

log "=== Starting Deployment ==="
log "Script: $DEPLOY_SCRIPT"
log "Time: $(date)"

# Run deployment script
# - Redirect all output to both console (journal) and log file
# - Capture exit code
set +e  # Don't exit on error yet - we want to handle it
bash "$DEPLOY_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
DEPLOY_EXIT_CODE=${PIPESTATUS[0]}
set -e

log "=== Deployment Finished ==="
log "Exit code: $DEPLOY_EXIT_CODE"

# ============================================================================
# Step 6: Report results
# ============================================================================

if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
    log "✓ Deployment completed successfully"
    
    send_notification \
        "GitOps: Deployment Successful" \
        "All services deployed successfully. Commit: ${CURRENT_HASH}" \
        "default" \
        "white_check_mark,rocket"
    
    exit 0
else
    log "✗ Deployment failed with exit code $DEPLOY_EXIT_CODE"
    log "Check logs for details: $LOG_FILE"
    
    send_notification \
        "GitOps: Deployment Failed" \
        "Deployment failed for commit ${CURRENT_HASH}. Check logs on manager-1." \
        "urgent" \
        "x,rocket"
    
    exit $DEPLOY_EXIT_CODE
fi
