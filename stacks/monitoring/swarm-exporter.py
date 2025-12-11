import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        lines = ["# HELP swarm_node_info Node info", "# TYPE swarm_node_info gauge"]
        result = subprocess.run(["docker", "node", "ls", "--format", "{{.Hostname}} {{.ManagerStatus}}"], capture_output=True, text=True)
        for line in result.stdout.strip().split("\n"):
            if line:
                p = line.split()
                role = "manager" if len(p) > 1 and p[1] else "worker"
                lines.append(f'swarm_node_info{{hostname="{p[0]}",role="{role}"}} 1')
        lines.extend(["", "# HELP swarm_service_replicas_running Running", "# TYPE swarm_service_replicas_running gauge", "# HELP swarm_service_replicas_desired Desired", "# TYPE swarm_service_replicas_desired gauge"])
        result = subprocess.run(["docker", "service", "ls", "--format", "{{.Name}} {{.Replicas}}"], capture_output=True, text=True)
        for line in result.stdout.strip().split("\n"):
            if line:
                p = line.split()
                r = p[1].split("/")
                lines.append(f'swarm_service_replicas_running{{service_name="{p[0]}"}} {r[0]}')
                lines.append(f'swarm_service_replicas_desired{{service_name="{p[0]}"}} {r[1]}')
        output = "\n".join(lines) + "\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(output.encode())
    def log_message(self, *a): pass

print("Starting swarm exporter on :9099")
HTTPServer(("0.0.0.0", 9099), Handler).serve_forever()
