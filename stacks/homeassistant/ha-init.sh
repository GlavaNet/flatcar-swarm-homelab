#!/bin/bash
set -e

CONFIG_FILE="/config/configuration.yaml"

# Only create config if it doesn't exist (first boot)
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating initial configuration.yaml with reverse proxy support..."
    cat > "$CONFIG_FILE" << 'EOF'
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.0.0.0/8
    - 172.16.0.0/12
    - 192.168.0.0/16

default_config:
EOF
    echo "Configuration created."
fi

# Start Home Assistant with original entrypoint
exec /init
