#!/usr/bin/env python3
import subprocess, json, hmac, hashlib, logging, time, os
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

LISTEN_PORT = 9999
WEBHOOK_SECRET = os.environ.get('WEBHOOK_SECRET', '')
JIT_SERVICES = {'mealie_mealie': 60, 'minio_minio': 30, 'forgejo_forgejo': 60}
    'vaultwarden_vaultwarden': 60,
    'vaultwarden_vaultwarden': 60,
SERVICE_MAP = {'mealie': 'mealie_mealie', 'minio': 'minio_minio', 'forgejo': 'forgejo_forgejo'}
    'vaultwarden': 'vaultwarden_vaultwarden',
    'vaultwarden': 'vaultwarden_vaultwarden',

logging.basicConfig(level=logging.INFO, format='[%(asctime)s] %(levelname)s: %(message)s')

def scale_service(service_name, replicas=1):
    try:
        logging.info(f"Scaling {service_name} to {replicas}")
        result = subprocess.run(['docker', 'service', 'scale', f'{service_name}={replicas}'], 
                              capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            logging.info(f"✓ {service_name} scaled to {replicas}")
            return True
        logging.error(f"✗ Failed: {result.stderr}")
        return False
    except Exception as e:
        logging.error(f"Error: {e}")
        return False

class WebhookHandler(BaseHTTPRequestHandler):
    def verify_signature(self, payload):
        if not WEBHOOK_SECRET:
            return True
        signature = self.headers.get('X-Hub-Signature-256', '')
        if not signature:
            return False
        expected = 'sha256=' + hmac.new(WEBHOOK_SECRET.encode(), payload, hashlib.sha256).hexdigest()
        return hmac.compare_digest(signature, expected)
    
    def start_service(self, service_name):
        try:
            if not scale_service(service_name, 1):
                return False, "Scale failed"
            return True, "Service started"
        except Exception as e:
            return False, str(e)
    
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'ok'}).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_POST(self):
        path = urlparse(self.path).path
        if path.startswith('/start/'):
            service_short = path.split('/start/')[1].strip('/')
            if not service_short:
                self.send_response(400)
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                return
            service_name = SERVICE_MAP.get(service_short, service_short)
            logging.info(f"[OPEN] {service_short} -> {service_name}")
            success, message = self.start_service(service_name)
            self.send_response(200 if success else 500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'success' if success else 'error', 
                                        'service': service_name, 'message': message}).encode())
        elif path.startswith('/github/'):
            content_length = int(self.headers.get('Content-Length', 0))
            payload = self.rfile.read(content_length)
            if not self.verify_signature(payload):
                self.send_response(403)
                self.end_headers()
                return
            service_short = path.split('/github/')[1].strip('/')
            service_name = SERVICE_MAP.get(service_short, service_short)
            success, _ = self.start_service(service_name)
            self.send_response(200 if success else 500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'success' if success else 'error'}).encode())
        else:
            self.send_response(404)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.end_headers()
    
    def log_message(self, format, *args):
        logging.info(f"{self.client_address[0]} - {format % args}")

def main():
    server = HTTPServer(('0.0.0.0', LISTEN_PORT), WebhookHandler)
    logging.info(f"Webhook Receiver on port {LISTEN_PORT}")
    logging.info("/start/* = OPEN | /github/* = AUTH")
    server.serve_forever()

if __name__ == '__main__':
    main()
