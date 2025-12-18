#!/bin/bash
# git-deploy-notify.sh - GitOps deployment wrapper with ntfy notifications
# IMPROVED VERSION with better error handling and debugging

set -e  # Exit on any error

# Configuration
REPO_DIR="/home/core/flatcar-swarm-homelab"
LOG_FILE="${REPO_DIR}/deploy.log"

# Get NTFY_TOPIC_URL from multiple sources (in order of preference)
if [ -z "$NTFY_TOPIC_URL" ]; then
    # Try .env.local
    if [ -f "${REPO_DIR}/.env.local" ]; then
        source "${REPO_DIR}/.env.local"
    fi
fi

if [ -z "$NTFY_TOPIC_URL" ]; then
    # Try ~/.ntfy-url
    if [ -f "$HOME/.ntfy-url" ]; then
        NTFY_TOPIC_URL=$(cat "$HOME/.ntfy-url")
    fi
fi

if [ -z "$NTFY_TOPIC_URL" ]; then
    # Default to local ntfy
    NTFY_TOPIC_URL="http://ntfy.local/swarm-alerts"
fi

# ============================================================================
# Functions
# ============================================================================

# Send notification to ntfy
send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-rocket}"
    
    # Always log to stdout/journal
    echo "[NTFY] $title: $message"
    
    # Skip if NTFY_TOPIC_URL is explicitly set to empty or "disabled"
    if [ -z "$NTFY_TOPIC_URL" ] || [ "$NTFY_TOPIC_URL" = "disabled" ]; then
        echo "[NTFY] Notifications disabled"
        return 0
    fi
    
    # Try to send to ntfy with timeout
    if timeout 10 curl -sf \
         -H "Title: ${title}" \
         -H "Priority: ${priority}" \
         -H "Tags: ${tags}" \
         -d "${message}" \
         "${NTFY_TOPIC_URL}" > /dev/null 2>&1; then
        echo "[NTFY] ✓ Notification sent"
        return 0
    else
        echo "[NTFY] ⚠️ Failed to send notification (endpoint may be unavailable)"
        # Don't fail the script if notifications fail
        return 0
    fi
}

# Log to both journal and file
log() {
    local message="$1"
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    echo "$timestamp $message"
    echo "$timestamp $message" >> "$LOG_FILE"
}

# ============================================================================
# Pre-flight checks
# ============================================================================

log "=== GitOps Deployment Check Started ==="
log "NTFY_TOPIC_URL: ${NTFY_TOPIC_URL}"

# Create log directory if needed
mkdir -p "$(dirname "$LOG_FILE")"

# Verify repository directory exists
if [ ! -d "$REPO_DIR" ]; then
    log "ERROR: Repository directory not found: $REPO_DIR"
    send_notification \
        "GitOps: Critical Error" \
        "Repository directory not found" \
        "urgent" \
        "x,file_folder"
    exit 1
fi

# Change to repository
cd "$REPO_DIR" || {
    log "ERROR: Cannot change to repository directory"
    send_notification \
        "GitOps: Critical Error" \
        "Cannot access repository" \
        "urgent" \
        "x,file_folder"
    exit 1
}

log "Working directory: $(pwd)"

# ============================================================================
# Test network connectivity
# ============================================================================

log "Testing network connectivity to GitHub..."

if timeout 5 curl -sf https://github.com > /dev/null 2>&1; then
    log "✓ GitHub is reachable"
else
    log "⚠️ GitHub may not be reachable (continuing anyway)"
fi

# ============================================================================
# Step 1: Fetch latest changes from origin
# ============================================================================

log "Fetching latest changes from origin/main..."

# Use timeout to prevent hanging
if timeout 30 git fetch origin 2>&1 | tee -a "$LOG_FILE"; then
    log "✓ Git fetch completed successfully"
else
    EXIT_CODE=$?
    log "ERROR: git fetch failed with exit code $EXIT_CODE"
    
    # More detailed error message
    if [ $EXIT_CODE -eq 124 ]; then
        log "ERROR: git fetch timed out after 30 seconds"
        send_notification \
            "GitOps: Fetch Timeout" \
            "Git fetch timed out - check network connectivity" \
            "high" \
            "x,git,clock"
    else
        send_notification \
            "GitOps: Fetch Failed" \
            "Git fetch failed - check logs on manager-1" \
            "high" \
            "x,git"
    fi
    
    exit 1
fi

# ============================================================================
# Step 2: Compare commits
# ============================================================================

LOCAL=$(git rev-parse HEAD 2>&1) || {
    log "ERROR: Cannot determine local commit"
    exit 1
}

REMOTE=$(git rev-parse origin/main 2>&1) || {
    log "ERROR: Cannot determine remote commit (fetch may have failed)"
    exit 1
}

log "Local commit:  $LOCAL"
log "Remote commit: $REMOTE"

# Check if up to date
if [ "$LOCAL" = "$REMOTE" ]; then
    log "✓ No new changes detected"
    exit 0
fi

log "✓ New changes detected!"

# ============================================================================
# Step 3: Get commit details
# ============================================================================

CURRENT_HASH=$(git rev-parse --short origin/main)
COMMIT_MSG=$(git log origin/main -1 --pretty=%B | head -n1)
COMMIT_AUTHOR=$(git log origin/main -1 --pretty="%an")

log "Commit: $CURRENT_HASH"
log "Author: $COMMIT_AUTHOR"
log "Message: $COMMIT_MSG"

# ============================================================================
# Step 4: Notify about deployment start
# ============================================================================

send_notification \
    "GitOps: Deployment Starting" \
    "Pulling changes: ${COMMIT_MSG}" \
    "default" \
    "rocket"

# ============================================================================
# Step 5: Pull changes
# ============================================================================

log "Resetting to origin/main..."

if git reset --hard origin/main 2>&1 | tee -a "$LOG_FILE"; then
    log "✓ Repository updated successfully"
else
    log "ERROR: git reset failed"
    send_notification \
        "GitOps: Update Failed" \
        "Failed to update repository" \
        "urgent" \
        "x,git"
    exit 1
fi

send_notification \
    "GitOps: Repository Updated" \
    "Commit: ${CURRENT_HASH} by ${COMMIT_AUTHOR}" \
    "default" \
    "git"

# ============================================================================
# Step 6: Find deployment script
# ============================================================================

log "Looking for deployment script..."

DEPLOY_SCRIPT=""

# Prefer deploy-services.sh
if [ -f scripts/deploy-services.sh ]; then
    DEPLOY_SCRIPT="scripts/deploy-services.sh"
    log "✓ Found deployment script: $DEPLOY_SCRIPT"
else
    log "ERROR: No deployment script found"
    log "Looked for: scripts/deploy-services.sh"
    
    send_notification \
        "GitOps: No Deploy Script" \
        "Deployment script not found in repository" \
        "urgent" \
        "x,rocket"
    
    exit 1
fi

# ============================================================================
# Step 7: Run deployment
# ============================================================================

log "=== Starting Deployment ==="
log "Script: $DEPLOY_SCRIPT"
log "Time: $(date)"
log ""

# Source environment if available
if [ -f .env.local ]; then
    log "Loading .env.local..."
    source .env.local
fi

# Run deployment
set +e  # Don't exit immediately on error
bash "$DEPLOY_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
DEPLOY_EXIT_CODE=${PIPESTATUS[0]}
set -e

log ""
log "=== Deployment Finished ==="
log "Exit code: $DEPLOY_EXIT_CODE"

# ============================================================================
# Step 8: Report results
# ============================================================================

if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
    log "✓ Deployment completed successfully"
    
    send_notification \
        "GitOps: Deployment Successful" \
        "Commit ${CURRENT_HASH} deployed successfully" \
        "default" \
        "white_check_mark,rocket"
    
    exit 0
else
    log "✗ Deployment failed with exit code $DEPLOY_EXIT_CODE"
    log "Check logs: $LOG_FILE"
    
    send_notification \
        "GitOps: Deployment Failed" \
        "Commit ${CURRENT_HASH} deployment failed. Check logs." \
        "urgent" \
        "x,rocket"
    
    exit $DEPLOY_EXIT_CODE
fi
