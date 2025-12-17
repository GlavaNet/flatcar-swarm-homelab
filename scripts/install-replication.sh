#!/bin/bash
# Install automated volume replication systemd service

set -e

echo "Installing volume replication service..."

# Copy script to /opt/bin
sudo cp replicate-volumes.sh /opt/bin/
sudo chmod +x /opt/bin/replicate-volumes.sh

# Create systemd service
sudo tee /etc/systemd/system/volume-replication.service > /dev/null << 'EOF'
[Unit]
Description=Replicate Docker volumes to backup managers
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/bin/replicate-volumes.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Create systemd timer
sudo tee /etc/systemd/system/volume-replication.timer > /dev/null << 'EOF'
[Unit]
Description=Run volume replication daily

[Timer]
OnBootSec=10min
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable volume-replication.timer
sudo systemctl start volume-replication.timer

echo "✓ Volume replication installed"
echo ""
echo "Status:"
sudo systemctl status volume-replication.timer --no-pager

echo ""
echo "Test replication:"
echo "  sudo systemctl start volume-replication.service"
echo ""
echo "View logs:"
echo "  journalctl -u volume-replication.service -f"
echo "  tail -f /var/log/volume-replication.log"
