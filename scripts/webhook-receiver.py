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
