#!/bin/bash
# Just-in-Time Service Management for Docker Swarm

set -e

SERVICES_DIR="/home/core/jit-services"
LOG_FILE="/var/log/jit-services.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Service configuration: service_name:timeout_minutes
declare -A JIT_SERVICES=(
    ["minio_minio"]="30"
    ["forgejo_forgejo"]="60"
    ["mealie_mealie"]="60"
)

# Start a service
start_service() {
    local service="$1"
    local timeout="${JIT_SERVICES[$service]:-30}"
    
    log "Starting $service (auto-shutdown in ${timeout}m)"
    
    # Scale up to 1 replica
    docker service scale "${service}=1"
    
    # Wait for service to be ready
    local max_wait=60
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if docker service ps "$service" 2>/dev/null | grep -q "Running"; then
            log "✓ $service is ready"
            
            # Schedule auto-shutdown
            mkdir -p "$SERVICES_DIR"
            echo "$(date -d "+${timeout} minutes" +%s)" > "$SERVICES_DIR/${service}.shutdown"
            
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    
    log "⚠ $service may not be ready yet (timeout reached)"
    return 1
}

# Stop a service
stop_service() {
    local service="$1"
    
    log "Stopping $service"
    docker service scale "${service}=0"
    rm -f "$SERVICES_DIR/${service}.shutdown"
    
    log "✓ $service stopped"
}

# Check for services that should auto-shutdown
check_auto_shutdown() {
    local now=$(date +%s)
    
    for service in "${!JIT_SERVICES[@]}"; do
        local shutdown_file="$SERVICES_DIR/${service}.shutdown"
        
        if [ -f "$shutdown_file" ]; then
            local shutdown_time=$(cat "$shutdown_file")
            
            if [ "$now" -ge "$shutdown_time" ]; then
                log "Auto-shutdown triggered for $service"
                stop_service "$service"
            fi
        fi
    done
}

# Get service status
status_service() {
    local service="$1"
    
    local replicas=$(docker service ls --filter "name=${service}" --format "{{.Replicas}}" 2>/dev/null || echo "0/0")
    local running=$(echo "$replicas" | cut -d'/' -f1)
    
    if [ "$running" = "0" ]; then
        echo "stopped"
    else
        echo "running"
    fi
}

# Main command handler
case "${1:-}" in
    start)
        if [ -z "$2" ]; then
            echo "Usage: $0 start <service_name>"
            echo "Available services: ${!JIT_SERVICES[*]}"
            exit 1
        fi
        
        service_name="$2"
        if [ -z "${JIT_SERVICES[$service_name]}" ]; then
            echo "Error: Unknown service. Available: ${!JIT_SERVICES[*]}"
            exit 1
        fi
        
        start_service "$service_name"
        ;;
    
    stop)
        if [ -z "$2" ]; then
            echo "Usage: $0 stop <service_name>"
            exit 1
        fi
        stop_service "$2"
        ;;
    
    status)
        echo "JIT Service Status:"
        echo ""
        for service in "${!JIT_SERVICES[@]}"; do
            status=$(status_service "$service")
            timeout="${JIT_SERVICES[$service]}"
            
            if [ "$status" = "running" ]; then
                shutdown_file="$SERVICES_DIR/${service}.shutdown"
                if [ -f "$shutdown_file" ]; then
                    shutdown_time=$(cat "$shutdown_file")
                    remaining=$(( (shutdown_time - $(date +%s)) / 60 ))
                    echo "  $service: ✓ RUNNING (auto-stop in ${remaining}m)"
                else
                    echo "  $service: ✓ RUNNING"
                fi
            else
                echo "  $service: ○ STOPPED (timeout: ${timeout}m)"
            fi
        done
        ;;
    
    check)
        check_auto_shutdown
        ;;
    
    *)
        echo "Docker Swarm Just-in-Time Service Manager"
        echo ""
        echo "Usage: $0 {start|stop|status|check} [service_name]"
        echo ""
        echo "Commands:"
        echo "  start <service>  - Start a service (auto-stops after timeout)"
        echo "  stop <service>   - Stop a service immediately"
        echo "  status          - Show all JIT service statuses"
        echo "  check           - Check for services to auto-shutdown (run via cron)"
        echo ""
        echo "Available services:"
        for service in "${!JIT_SERVICES[@]}"; do
            echo "  - $service (timeout: ${JIT_SERVICES[$service]}m)"
        done
        exit 1
        ;;
esac
