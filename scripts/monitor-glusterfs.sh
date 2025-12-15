#!/bin/bash
# Monitor GlusterFS for extended period (24h recommended)

set -e

DURATION=${1:-86400}  # Default 24 hours
INTERVAL=300          # Sample every 5 minutes
LOG_FILE="/var/log/glusterfs-monitor.log"

echo "=== GlusterFS Long-term Monitor ===" | tee -a "$LOG_FILE"
echo "Duration: $((DURATION / 3600)) hours" | tee -a "$LOG_FILE"
echo "Started: $(date)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

START_TIME=$(date +%s)

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED -ge $DURATION ]; then
        break
    fi
    
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # System metrics
    MEM_USAGE=$(free | awk '/^Mem:/ {printf "%.1f%%", $3/$2*100}')
    MEM_AVAIL=$(free -h | awk '/^Mem:/ {print $7}')
    
    # Container stats
    GLUSTER_STATS=$(docker stats --no-stream --format "{{.MemPerc}} {{.CPUPerc}}" \
        $(docker ps -q -f name=glusterfs_glusterfs | head -1) 2>/dev/null || echo "N/A N/A")
    
    # Volume health
    GLUSTER_CONTAINER=$(docker ps -q -f name=glusterfs_glusterfs | head -1)
    if [ -n "$GLUSTER_CONTAINER" ]; then
        BRICK_STATUS=$(docker exec "$GLUSTER_CONTAINER" gluster volume status gv0 2>/dev/null | \
            grep -c "Online" || echo "0")
    else
        BRICK_STATUS="N/A"
    fi
    
    # Log entry
    echo "[$TIMESTAMP] Mem: $MEM_USAGE (Avail: $MEM_AVAIL) | GlusterFS: $GLUSTER_STATS | Bricks Online: $BRICK_STATUS" | \
        tee -a "$LOG_FILE"
    
    sleep $INTERVAL
done

echo "" | tee -a "$LOG_FILE"
echo "Monitoring complete: $(date)" | tee -a "$LOG_FILE"
echo "Log saved to: $LOG_FILE" | tee -a "$LOG_FILE"
