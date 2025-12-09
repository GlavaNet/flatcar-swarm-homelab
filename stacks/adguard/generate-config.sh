#!/bin/bash
# Generate AdGuard config from template

set -e

TEMPLATE="config/AdGuardHome.yaml.template"
OUTPUT="config/AdGuardHome.yaml"

# Default values
ADMIN_PASSWORD="${ADGUARD_ADMIN_PASSWORD:-admin}"
UPSTREAM_DNS_1="${ADGUARD_UPSTREAM_DNS_1:-https://dns.quad9.net/dns-query}"
UPSTREAM_DNS_2="${ADGUARD_UPSTREAM_DNS_2:-https://dns.cloudflare.com/dns-query}"
LOCAL_DOMAIN="${ADGUARD_LOCAL_DOMAIN:-local}"
MANAGER_IP="${ADGUARD_MANAGER_IP:-192.168.99.101}"

# Generate password hash
PASSWORD_HASH=$(docker run --rm alpine/openssl passwd -6 "$ADMIN_PASSWORD")

# Replace variables in template
sed -e "s|{{PASSWORD_HASH}}|${PASSWORD_HASH}|g" \
    -e "s|{{UPSTREAM_DNS_1}}|${UPSTREAM_DNS_1}|g" \
    -e "s|{{UPSTREAM_DNS_2}}|${UPSTREAM_DNS_2}|g" \
    -e "s|{{LOCAL_DOMAIN}}|${LOCAL_DOMAIN}|g" \
    -e "s|{{MANAGER_IP}}|${MANAGER_IP}|g" \
    "$TEMPLATE" > "$OUTPUT"

echo "AdGuard config generated: $OUTPUT"
