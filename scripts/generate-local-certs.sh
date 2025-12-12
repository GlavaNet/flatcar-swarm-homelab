#!/bin/bash
# Generate self-signed certificates for local HTTPS access

set -e

CERT_DIR="/home/core/certs"
SERVICES=("vault" "ha" "traefik" "git" "grafana" "prometheus" "alertmanager" "adguard")

echo "=== Self-Signed Certificate Generator ==="
echo ""
echo "This script generates self-signed certificates for local .local domain access"
echo "Certificates will be stored in: $CERT_DIR"
echo ""

# Create cert directory if it doesn't exist
mkdir -p "$CERT_DIR"

# Generate certificates for each service
for service in "${SERVICES[@]}"; do
    CERT_FILE="$CERT_DIR/${service}.crt"
    KEY_FILE="$CERT_DIR/${service}.key"
    
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✓ Certificate already exists for ${service}.local"
    else
        echo "Generating certificate for ${service}.local..."
        
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -subj "/C=US/ST=State/L=City/O=Homelab/CN=${service}.local" \
            -addext "subjectAltName=DNS:${service}.local" \
            2>/dev/null
        
        echo "✓ Generated: ${service}.crt and ${service}.key"
    fi
done

# Create a combined certificate file that includes all services
echo ""
echo "Creating combined certificate file for Traefik..."
cat "$CERT_DIR"/*.crt > "$CERT_DIR/combined.crt"
cat "$CERT_DIR"/*.key > "$CERT_DIR/combined.key"

# Set proper permissions
chmod 600 "$CERT_DIR"/*.key
chmod 644 "$CERT_DIR"/*.crt

echo ""
echo "=== Certificate Generation Complete ==="
echo ""
echo "Certificates created in: $CERT_DIR"
echo ""
echo "To trust these certificates on your local machine:"
echo ""
echo "Linux:"
echo "  sudo cp $CERT_DIR/*.crt /usr/local/share/ca-certificates/"
echo "  sudo update-ca-certificates"
echo ""
echo "macOS:"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CERT_DIR/vault.crt"
echo ""
echo "Windows:"
echo "  1. Copy .crt files to your Windows machine"
echo "  2. Double-click each .crt file"
echo "  3. Click 'Install Certificate'"
echo "  4. Choose 'Local Machine' → 'Trusted Root Certification Authorities'"
echo ""
echo "Browser-specific (if needed):"
echo "  Firefox: Preferences → Privacy & Security → Certificates → View Certificates → Import"
echo "  Chrome uses system certificates (follow OS instructions above)"
echo ""
