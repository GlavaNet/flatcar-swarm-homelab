#!/bin/bash
# git-deploy-notify.sh - Wrap deployment with ntfy notifications

set -e

NTFY_URL="${NTFY_TOPIC_URL:-http://ntfy.local/swarm-alerts}"
REPO_DIR="/home/core/flatcar-swarm-homelab"
LOG_FILE="${REPO_DIR}/deploy.log"

# Function to send notification
send_notification() {
    local title="$1"
    local message="$2"
    local priority="$3"
    local tags="$4"
    
    curl -H "Title: ${title}" \
         -H "Priority: ${priority}" \
         -H "Tags: ${tags}" \
         -d "${message}" \
         "${NTFY_URL}" 2>/dev/null || true
}

cd "$REPO_DIR"

# Fetch changes
git fetch origin

# Check if there are new commits
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" = "$REMOTE" ]; then
    # No changes, exit silently
    exit 0
fi

# There are changes, send notification and deploy
send_notification \
    "GitOps: Deployment Starting" \
    "Pulling latest changes from repository..." \
    "default" \
    "rocket"

git reset --hard origin/main
CURRENT_HASH=$(git rev-parse --short HEAD)
COMMIT_MSG=$(git log -1 --pretty=%B | head -n1)

send_notification \
    "GitOps: Repository Updated" \
    "Commit: ${CURRENT_HASH} - ${COMMIT_MSG}" \
    "default" \
    "git"

# Deploy services
if bash scripts/deploy-services.sh > "$LOG_FILE" 2>&1; then
    send_notification \
        "GitOps: Deployment Successful" \
        "All services deployed successfully. Commit: ${CURRENT_HASH}" \
        "default" \
        "white_check_mark,rocket"
else
    send_notification \
        "GitOps: Deployment Failed" \
        "Deployment failed for commit ${CURRENT_HASH}. Check logs on manager-1." \
        "urgent" \
        "x,rocket"
    exit 1
fi
