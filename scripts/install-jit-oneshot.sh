#!/bin/bash
# One-Shot JIT Service Installation Script
# This script downloads all necessary files and installs the JIT system

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}===================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}===================================${NC}"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Check if running on manager node
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    print_error "This script must be run on a Docker Swarm manager node"
    exit 1
fi

if ! docker node ls 2>/dev/null | grep -q "Leader"; then
    print_warn "This script should be run on the primary manager (manager-1)"
    read -p "Continue anyway? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        exit 0
    fi
fi

print_header "JIT Service One-Shot Installer"
echo ""
echo "This script will:"
echo "  1. Download all JIT service files"
echo "  2. Copy them to appropriate locations"
echo "  3. Install systemd units"
echo "  4. Generate webhook secrets"
echo "  5. Start JIT services"
echo "  6. Scale JIT services to 0"
echo ""
read -p "Continue? (y/n): " confirm
if [ "$confirm" != "y" ]; then
    exit 0
fi

# Create temporary directory
TEMP_DIR="/tmp/jit-install-$(date +%s)"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

print_header "Step 1: Creating JIT Service Files"

# Create jit-services.sh
print_info "Creating jit-services.sh..."
cat > jit-services.sh << 'EOFSCRIPT'
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
EOFSCRIPT

chmod +x jit-services.sh
print_success "Created jit-services.sh"

# Create webhook-receiver.py
print_info "Creating webhook-receiver.py..."
cat > webhook-receiver.py << 'EOFPYTHON'
#!/usr/bin/env python3
"""
Webhook receiver for just-in-time service activation
Listens for GitHub webhooks and starts Forgejo automatically
"""

import hmac
import hashlib
import subprocess
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import json
import os

# Configuration
WEBHOOK_SECRET = os.environ.get('WEBHOOK_SECRET', 'change-me-in-production')
JIT_SCRIPT = '/opt/bin/jit-services.sh'
PORT = 9999

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    handlers=[
        logging.FileHandler('/var/log/webhook-receiver.log'),
        logging.StreamHandler()
    ]
)

class WebhookHandler(BaseHTTPRequestHandler):
    
    def verify_signature(self, payload, signature):
        """Verify GitHub webhook signature"""
        if not signature:
            return False
        
        expected = 'sha256=' + hmac.new(
            WEBHOOK_SECRET.encode(),
            payload,
            hashlib.sha256
        ).hexdigest()
        
        return hmac.compare_digest(expected, signature)
    
    def start_service(self, service_name):
        """Start a JIT service"""
        try:
            result = subprocess.run(
                [JIT_SCRIPT, 'start', service_name],
                capture_output=True,
                text=True,
                timeout=120
            )
            
            if result.returncode == 0:
                logging.info(f"Started {service_name}")
                return True
            else:
                logging.error(f"Failed to start {service_name}: {result.stderr}")
                return False
        except Exception as e:
            logging.error(f"Error starting {service_name}: {e}")
            return False
    
    def do_POST(self):
        """Handle webhook POST requests"""
        path = urlparse(self.path).path
        
        # Get payload
        content_length = int(self.headers.get('Content-Length', 0))
        payload = self.rfile.read(content_length)
        
        # Verify signature
        signature = self.headers.get('X-Hub-Signature-256')
        if not self.verify_signature(payload, signature):
            logging.warning(f"Invalid signature from {self.client_address[0]}")
            self.send_response(403)
            self.end_headers()
            return
        
        # Route based on path
        if path == '/github/forgejo':
            # GitHub webhook for Forgejo mirror
            event = self.headers.get('X-GitHub-Event')
            logging.info(f"Received GitHub {event} event")
            
            if event in ['push', 'pull_request', 'release']:
                if self.start_service('forgejo_forgejo'):
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(b'{"status": "service_started"}')
                else:
                    self.send_response(500)
                    self.end_headers()
            else:
                self.send_response(200)
                self.end_headers()
        
        elif path == '/start/minio':
            # Manual trigger for MinIO
            if self.start_service('minio_minio'):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status": "minio_started"}')
            else:
                self.send_response(500)
                self.end_headers()
        
        elif path == '/start/mealie':
            # Manual trigger for Mealie
            if self.start_service('mealie_mealie'):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status": "mealie_started"}')
            else:
                self.send_response(500)
                self.end_headers()
        
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_GET(self):
        """Health check endpoint"""
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status": "ok"}')
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        """Override to use our logger"""
        logging.info(f"{self.client_address[0]} - {format % args}")

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', PORT), WebhookHandler)
    logging.info(f"Webhook receiver listening on port {PORT}")
    logging.info(f"Endpoints: /github/forgejo, /start/minio, /start/mealie")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutting down...")
        server.shutdown()
EOFPYTHON

chmod +x webhook-receiver.py
print_success "Created webhook-receiver.py"

# Create backup-to-minio-jit.sh
print_info "Creating backup-to-minio-jit.sh..."
cat > backup-to-minio-jit.sh << 'EOFBACKUP'
#!/bin/bash
# Automated backup to MinIO with Just-in-Time activation

set -e

MANAGER_NODES=("192.168.99.101" "192.168.99.102" "192.168.99.103")
VOLUME_PATTERNS=("vaultwarden" "homeassistant" "forgejo" "grafana" "mealie" "adguard")
DATE=$(date +%Y%m%d-%H%M)
MINIO_PASSWORD=$(cat ~/.minio-password 2>/dev/null || echo "")
JIT_SCRIPT="/opt/bin/jit-services.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Start MinIO if not running
log "Ensuring MinIO is available..."
if ! docker service ps minio_minio 2>/dev/null | grep -q "Running"; then
    log "Starting MinIO for backup..."
    
    if [ -x "$JIT_SCRIPT" ]; then
        $JIT_SCRIPT start minio_minio
    else
        docker service scale minio_minio=1
    fi
    
    # Wait for MinIO to be ready
    sleep 30
    
    local max_wait=60
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if curl -sf http://192.168.99.101:9000/minio/health/live > /dev/null 2>&1; then
            log "MinIO is ready"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
fi

if [ -z "$MINIO_PASSWORD" ]; then
    log "ERROR: MinIO password not found in ~/.minio-password"
    exit 1
fi

# Find which node has which volumes
declare -A VOLUME_LOCATIONS

for node in "${MANAGER_NODES[@]}"; do
    log "Scanning volumes on $node..."
    
    volumes=$(ssh -o ConnectTimeout=5 core@$node "docker volume ls --format '{{.Name}}'" 2>/dev/null || echo "")
    
    for pattern in "${VOLUME_PATTERNS[@]}"; do
        matching=$(echo "$volumes" | grep "$pattern" || true)
        
        for vol in $matching; do
            if [ -n "$vol" ]; then
                VOLUME_LOCATIONS["$vol"]="$node"
            fi
        done
    done
done

# Backup each discovered volume
for vol in "${!VOLUME_LOCATIONS[@]}"; do
    node="${VOLUME_LOCATIONS[$vol]}"
    
    log "Backing up $vol from $node..."
    
    if [ "$node" = "$(hostname -I | awk '{print $1}')" ] || [ "$node" = "192.168.99.101" ]; then
        # Local backup
        docker run --rm \
            -v ${vol}:/source:ro \
            alpine:latest \
            tar czf - -C /source . | \
        docker run --rm -i \
            -e MC_HOST_homelab="http://minioadmin:${MINIO_PASSWORD}@192.168.99.101:9000" \
            minio/mc:latest \
            mc pipe homelab/backups/${vol}-${DATE}.tar.gz
    else
        # Remote backup
        ssh core@$node "docker run --rm -v ${vol}:/source:ro alpine tar czf - -C /source ." | \
        docker run --rm -i \
            -e MC_HOST_homelab="http://minioadmin:${MINIO_PASSWORD}@192.168.99.101:9000" \
            minio/mc:latest \
            mc pipe homelab/backups/${vol}-${DATE}.tar.gz
    fi
    
    log "✓ Backed up $vol (from $node)"
done

log "=== Backup Complete ==="
log "Backed up ${#VOLUME_LOCATIONS[@]} volumes to MinIO"
log "MinIO will auto-stop in 30 minutes"
EOFBACKUP

chmod +x backup-to-minio-jit.sh
print_success "Created backup-to-minio-jit.sh"

# Create systemd units
print_info "Creating systemd unit files..."

cat > jit-checker.service << 'EOFUNIT'
[Unit]
Description=Just-in-Time Service Auto-Shutdown Checker
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/bin/jit-services.sh check
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOFUNIT

print_success "Created jit-checker.service"

cat > jit-checker.timer << 'EOFTIMER'
[Unit]
Description=Check JIT services every 5 minutes
Requires=jit-checker.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=jit-checker.service

[Install]
WantedBy=timers.target
EOFTIMER

print_success "Created jit-checker.timer"

cat > webhook-receiver.service << 'EOFWEBHOOK'
[Unit]
Description=JIT Service Webhook Receiver
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
User=core
Group=core
Environment="WEBHOOK_SECRET=your-secret-here-change-me"
ExecStart=/usr/bin/python3 /opt/bin/webhook-receiver.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOFWEBHOOK

print_success "Created webhook-receiver.service"

print_header "Step 2: Installing Files"

# Copy scripts to /opt/bin/
print_info "Copying scripts to /opt/bin/..."
sudo cp jit-services.sh /opt/bin/
sudo cp webhook-receiver.py /opt/bin/
sudo cp backup-to-minio-jit.sh /opt/bin/
sudo chmod +x /opt/bin/jit-services.sh
sudo chmod +x /opt/bin/webhook-receiver.py
sudo chmod +x /opt/bin/backup-to-minio-jit.sh
print_success "Scripts installed to /opt/bin/"

# Replace old backup script or keep both
if [ -f /opt/bin/backup-to-minio.sh ]; then
    print_warn "Found existing backup-to-minio.sh"
    echo ""
    echo "Options:"
    echo "  1. Replace with JIT version (recommended)"
    echo "  2. Keep both (backup-to-minio.sh and backup-to-minio-jit.sh)"
    read -p "Choice (1 or 2): " backup_choice
    
    if [ "$backup_choice" = "1" ]; then
        sudo cp /opt/bin/backup-to-minio.sh /opt/bin/backup-to-minio.sh.old
        sudo cp /opt/bin/backup-to-minio-jit.sh /opt/bin/backup-to-minio.sh
        print_success "Replaced backup script (old version saved as .old)"
    else
        print_info "Keeping both backup scripts"
    fi
fi

# Install systemd units
print_info "Installing systemd units..."
sudo cp jit-checker.service /etc/systemd/system/
sudo cp jit-checker.timer /etc/systemd/system/
sudo cp webhook-receiver.service /etc/systemd/system/
print_success "Systemd units installed"

print_header "Step 3: Generating Webhook Secret"

# Generate webhook secret
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo "$WEBHOOK_SECRET" > ~/.webhook-secret
chmod 600 ~/.webhook-secret
print_success "Webhook secret generated and saved to ~/.webhook-secret"

# Update webhook service with secret
sudo sed -i "s/your-secret-here-change-me/$WEBHOOK_SECRET/" /etc/systemd/system/webhook-receiver.service
print_success "Webhook secret configured in systemd service"

# Create JIT services directory
mkdir -p /home/core/jit-services
print_success "Created JIT services directory"

print_header "Step 4: Enabling and Starting Services"

# Reload systemd
sudo systemctl daemon-reload
print_success "Systemd reloaded"

# Enable and start timer
sudo systemctl enable jit-checker.timer
sudo systemctl start jit-checker.timer
print_success "Auto-shutdown checker enabled and started"

# Enable and start webhook receiver
sudo systemctl enable webhook-receiver.service
sudo systemctl start webhook-receiver.service
print_success "Webhook receiver enabled and started"

# Give webhook receiver a moment to start
sleep 2

# Check if webhook receiver is running
if sudo systemctl is-active --quiet webhook-receiver.service; then
    print_success "Webhook receiver is running"
else
    print_warn "Webhook receiver may have failed to start"
    echo "Check logs with: sudo journalctl -u webhook-receiver.service -n 20"
fi

print_header "Step 5: Configuring JIT Services"

# Scale down JIT services to 0 initially
echo ""
print_info "Scaling JIT services to 0 replicas..."

if docker service ls 2>/dev/null | grep -q minio_minio; then
    docker service scale minio_minio=0 2>/dev/null && print_success "MinIO scaled to 0" || print_warn "MinIO not found or already at 0"
else
    print_info "MinIO service not yet deployed"
fi

if docker service ls 2>/dev/null | grep -q forgejo_forgejo; then
    docker service scale forgejo_forgejo=0 2>/dev/null && print_success "Forgejo scaled to 0" || print_warn "Forgejo not found or already at 0"
else
    print_info "Forgejo service not yet deployed"
fi

if docker service ls 2>/dev/null | grep -q mealie_mealie; then
    docker service scale mealie_mealie=0 2>/dev/null && print_success "Mealie scaled to 0" || print_warn "Mealie not found or already at 0"
else
    print_info "Mealie service not yet deployed"
fi

print_header "Installation Complete!"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "JIT Service Management Commands:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Status:"
echo "  /opt/bin/jit-services.sh status"
echo ""
echo "Start a service:"
echo "  /opt/bin/jit-services.sh start minio_minio"
echo "  /opt/bin/jit-services.sh start forgejo_forgejo"
echo "  /opt/bin/jit-services.sh start mealie_mealie"
echo ""
echo "Stop a service:"
echo "  /opt/bin/jit-services.sh stop <service_name>"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Webhook Endpoints (Port 9999):"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "GitHub webhook (for Forgejo):"
echo "  http://$(hostname -I | awk '{print $1}'):9999/github/forgejo"
echo ""
echo "Manual triggers:"
echo "  curl -X POST http://$(hostname -I | awk '{print $1}'):9999/start/minio"
echo "  curl -X POST http://$(hostname -I | awk '{print $1}'):9999/start/mealie"
echo ""
echo "Health check:"
echo "  curl http://$(hostname -I | awk '{print $1}'):9999/health"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Webhook Secret (for GitHub configuration):"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "$WEBHOOK_SECRET"
echo ""
echo "This secret has been saved to: ~/.webhook-secret"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "GitHub Webhook Setup:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "1. Go to your GitHub repo → Settings → Webhooks → Add webhook"
echo "2. Payload URL: http://YOUR_PUBLIC_IP:9999/github/forgejo"
echo "3. Content type: application/json"
echo "4. Secret: [paste from above]"
echo "5. Events: push, pull_request, release"
echo "6. Active: ✓"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Service Status:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
/opt/bin/jit-services.sh status
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Systemd Services:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Auto-shutdown checker:"
sudo systemctl status jit-checker.timer --no-pager | grep -E "(Active|Trigger)"
echo ""
echo "Webhook receiver:"
sudo systemctl status webhook-receiver.service --no-pager | grep "Active"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Logs:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "JIT operations:"
echo "  tail -f /var/log/jit-services.log"
echo ""
echo "Webhook receiver:"
echo "  sudo journalctl -u webhook-receiver.service -f"
echo ""
echo "Auto-shutdown checker:"
echo "  sudo journalctl -u jit-checker.service -f"
echo ""
echo "═══════════════════════════════════════════════════════════════"

# Cleanup
print_info "Cleaning up temporary files..."
cd /
rm -rf "$TEMP_DIR"
print_success "Cleanup complete"

echo ""
print_header "Installation Successful! 🎉"
echo ""
echo "Run '/opt/bin/jit-services.sh status' to see current service states"
echo ""
