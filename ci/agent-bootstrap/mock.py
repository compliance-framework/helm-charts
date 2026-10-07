"""Mock of the CCF API and the Kubernetes Secrets API for the agent bootstrap script tests.

Responses mirror api v0.21.0: echo's compact encoding/json output, GenericDataResponse
wrappers and agentResponse / agentKeyCreateResponse field order. Every request is appended to
/state/requests.log as a JSON line. The scenario comes from /state/scenario.json.
"""
import base64
import json
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = "/state"
with open(f"{STATE}/scenario.json") as f:
    SCENARIO = json.load(f)

API_TOKEN = SCENARIO["api_token"]
K8S_TOKEN = SCENARIO["k8s_token"]
agents = list(SCENARIO.get("agents", []))
secrets = {s: {} for s in SCENARIO.get("secrets", [])}
keys = {}


def compact(obj):
    return json.dumps(obj, separators=(",", ":"))


def agent_json(agent):
    out = {"id": agent["id"], "created-at": "2026-10-06T10:00:00.123456Z",
           "updated-at": "2026-10-06T10:00:00.123456Z", "name": agent["name"]}
    if agent.get("description") is not None:
        out["description"] = agent["description"]
    out["is-active"] = True
    out["service-account-key-count"] = 0
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=None):
        data = b"" if body is None else compact(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        with open(f"{STATE}/requests.log", "a") as log:
            log.write(compact({"method": self.command, "path": self.path, "body": raw,
                               "auth": self.headers.get("Authorization", "")}) + "\n")
        path, method, auth = self.path, self.command, self.headers.get("Authorization", "")

        if path.startswith("/api/v1/namespaces/"):
            if auth != f"Bearer {K8S_TOKEN}":
                return self.reply(401, {"kind": "Status", "message": "Unauthorized"})
            parts = path.split("/")  # ['', 'api', 'v1', 'namespaces', ns, 'secrets', name?]
            ns = parts[4]
            if method == "GET" and len(parts) == 7:
                key = f"{ns}/{parts[6]}"
                if key in secrets:
                    return self.reply(200, {"kind": "Secret", "metadata": {"name": parts[6]}})
                return self.reply(404, {"kind": "Status", "message": f"secrets \"{parts[6]}\" not found"})
            if method == "POST" and len(parts) == 6:
                status = SCENARIO.get("secret_create_status", 201)
                if status != 201:
                    return self.reply(status, {"kind": "Status", "message": "secrets is forbidden"})
                body = json.loads(raw)
                secrets[f"{ns}/{body['metadata']['name']}"] = body
                with open(f"{STATE}/secrets.json", "w") as out:
                    json.dump(secrets, out)
                return self.reply(201, body)
            return self.reply(405, {"message": "unexpected"})

        if path == "/api/health/ready" and method == "GET":
            return self.reply(200, {"status": "ok"})
        if path == "/api/auth/login" and method == "POST":
            body = json.loads(raw)
            if body.get("email") == SCENARIO["admin_email"] and body.get("password") == SCENARIO["admin_password"]:
                return self.reply(200, {"data": {"auth_token": API_TOKEN}})
            return self.reply(401, {"data": {"email": ["Invalid email or password"]}})

        if auth != f"Bearer {API_TOKEN}":
            return self.reply(401, {"code": 401, "errors": {"body": "missing or malformed jwt"}})
        if path == "/api/admin/agents" and method == "GET":
            return self.reply(200, {"data": [agent_json(a) for a in agents]})
        if path == "/api/admin/agents" and method == "POST":
            body = json.loads(raw)
            agent = {"id": str(uuid.uuid4()), "name": body["name"], "description": body.get("description")}
            agents.append(agent)
            return self.reply(201, {"data": agent_json(agent)})
        if path.startswith("/api/admin/agents/") and path.endswith("/keys") and method == "POST":
            body = json.loads(raw)
            key_id = str(uuid.uuid4())
            secret = base64.urlsafe_b64encode(uuid.uuid4().bytes + uuid.uuid4().bytes).decode().rstrip("=")
            key = {"id": key_id, "created-at": "2026-10-06T10:00:00.123456Z",
                   "updated-at": "2026-10-06T10:00:00.123456Z", "name": body.get("name"),
                   "client-id": str(uuid.uuid4()), "never-expires": True, "client-secret": secret}
            keys[key_id] = key
            with open(f"{STATE}/keys.json", "w") as out:
                json.dump(keys, out)
            return self.reply(201, {"data": key})
        if "/keys/" in path and method == "DELETE":
            return self.reply(204)
        return self.reply(404, {"message": "not found"})

    do_GET = do_POST = do_DELETE = handle_any


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
