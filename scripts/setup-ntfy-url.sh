#!/bin/bash
# Helper script to manage ntfy URL configuration

NTFY_FILE="$HOME/.ntfy-url"

# Function to get or create ntfy URL
get_or_create_ntfy_url() {
    if [ -f "$NTFY_FILE" ]; then
        # Use existing URL
        cat "$NTFY_FILE"
        return 0
    else
        # Generate new unique URL with random topic
        local random_string=$(openssl rand -hex 6)
        local ntfy_url="https://ntfy.sh/swarm-${random_string}-alerts"
        
        # Save to file
        echo "$ntfy_url" > "$NTFY_FILE"
        chmod 600 "$NTFY_FILE"
        
        echo "$ntfy_url"
        return 0
    fi
}

# Function to check if ntfy is configured
is_ntfy_configured() {
    if [ -f "$NTFY_FILE" ] && [ -s "$NTFY_FILE" ]; then
        return 0
    else
        return 1
    fi
}

# If called directly, output the URL
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    get_or_create_ntfy_url
fi
