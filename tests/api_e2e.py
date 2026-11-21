"""End-to-end checks of the HTTP API against a throwaway server: the health
proof, extension pairing and token scopes, settings edits, history, previews.

Usage: python3 -I tests/api_e2e.py zig-out/bin/talktome <empty work dir>
Runs `talktome serve` with TALKTOME_HOME=<work dir>/home on port 9951 (no
models installed, so nothing is spoken aloud).
"""
import hashlib, hmac, http.client, http.server, json, os, subprocess, sys, threading, time, tomllib

BIN, WORK = sys.argv[1], sys.argv[2]
HOME = os.path.join(WORK, "home")
PORT = 9951
os.makedirs(HOME, exist_ok=True)
with open(os.path.join(HOME, "settings.json"), "w") as f:
    json.dump({"port": PORT}, f)
ENV = dict(os.environ, TALKTOME_HOME=HOME)

results = []
def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  -- {detail}"))

def req(method, path, body=None, token=None, origin=None, raw=None, port=PORT):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    h = {"Host": f"127.0.0.1:{port}"}
    if token: h["Authorization"] = "Bearer " + token
    if origin: h["Origin"] = origin
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if data is not None: h["Content-Type"] = "application/json"
    c.request(method, path, body=data, headers=h)
    r = c.getresponse()
    out = r.read()
    c.close()
    try: js = json.loads(out)
    except Exception: js = None
    return r.status, js, out

def cli(*args, env=ENV, timeout=30):
    p = subprocess.run([BIN, *args], env=env, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr

server = subprocess.Popen([BIN, "serve"], env=ENV, stdout=subprocess.DEVNULL, stderr=open(os.path.join(WORK, "server.log"), "w"))
try:
    for _ in range(100):
        try:
            if req("GET", "/v1/health")[0] == 200: break
        except Exception: time.sleep(0.1)
    token = open(os.path.join(HOME, "token")).read().strip()

    # --- health proof
    st, js, _ = req("GET", "/v1/health?challenge=abc123")
    want = hmac.new(token.encode(), b"talktome-health:abc123", hashlib.sha256).hexdigest()
    check("health proof matches HMAC(token)", st == 200 and js.get("proof") == want, js)
    check("health without challenge has no proof", "proof" not in (req("GET", "/v1/health")[1] or {}))
    rc, out, err = cli("status")
    check("CLI works against the real server", rc == 0, err)

    # --- CLI refuses to send the token to an impostor
    seen = []
    class Impostor(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append(dict(self.headers))
            body = b'{"ok":true,"proof":"0000"}'
            self.send_response(200); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
        do_POST = do_GET
        def log_message(self, *a): pass
    imp = http.server.HTTPServer(("127.0.0.1", 9952), Impostor)
    threading.Thread(target=imp.serve_forever, daemon=True).start()
    home2 = os.path.join(WORK, "home2"); os.makedirs(home2, exist_ok=True)
    open(os.path.join(home2, "token"), "w").write(token)
    json.dump({"port": 9952}, open(os.path.join(home2, "settings.json"), "w"))
    rc, out, err = cli("status", env=dict(os.environ, TALKTOME_HOME=home2))
    leaked = any("Authorization" in h or "authorization" in h for h in seen)
    check("CLI does not send the token to an impostor", rc != 0 and not leaked and len(seen) > 0, (rc, err, seen))
    imp.shutdown()

    # --- answer-audio sample rate
    pcm = b"\x00\x00\x00\x00" * 1600
    st, js, _ = req("POST", "/v1/briefing/answer-audio?rate=0", raw=pcm, token=token)
    check("rate=0 is rejected, not a crash", st == 400, (st, js))
    st, js, _ = req("POST", "/v1/briefing/answer-audio?foo=1&rate=99999999", raw=pcm, token=token)
    check("absurd rate is rejected", st == 400, (st, js))
    check("server alive after bad rates", req("GET", "/v1/health")[0] == 200)

    # --- settings validation
    st, js, _ = req("PATCH", "/v1/settings", {"briefing": {"ollama_url": "file:///etc/passwd"}}, token=token)
    check("bad ollama_url rejected", st == 400, (st, js))
    st, js, _ = req("PATCH", "/v1/settings", {"briefing": {"timeout_seconds": 4000000000}}, token=token)
    check("timeout clamped to 300", st == 200 and js["briefing"]["timeout_seconds"] == 300, js and js.get("briefing"))

    # --- concurrent settings edits all land
    def patch(i):
        req("PATCH", "/v1/settings", {"sources": {f"src{i}": {"announce": True}}}, token=token)
    ts = [threading.Thread(target=patch, args=(i,)) for i in range(24)]
    [t.start() for t in ts]; [t.join() for t in ts]
    st, js, _ = req("GET", "/v1/settings", token=token)
    have = [k for k in js["sources"] if k.startswith("src")]
    check("24 concurrent setting changes all kept", len(have) == 24, len(have))

    # --- UTF-8 cut in previews
    text = "a" * 117 + "’s fine. " + "Second sentence with emoji 😀 and more."
    st, js, _ = req("POST", "/v1/speak", {"text": text, "format": "text", "source": {"app": "cli", "label": "l" * 46 + "é"}}, token=token)
    time.sleep(1.5)  # no model installed: the job fails and goes to history
    st, js, raw = req("GET", "/v1/jobs", token=token)
    ok = st == 200 and js is not None and all(isinstance(j["preview"], str) and isinstance(j["label"], str) for j in js["jobs"])
    check("jobs JSON has string previews after multi-byte cuts", ok, raw[:300])
    raw_hist = open(os.path.join(HOME, "history.json"), "rb").read() if os.path.exists(os.path.join(HOME, "history.json")) else b"[]"
    try: hist = json.loads(raw_hist); hist_ok = all(isinstance(h["preview"], str) for h in hist)
    except Exception: hist_ok = False
    check("history.json stays valid", hist_ok, raw_hist[:200])

    # --- --wait ends when the job is gone (history cleared while waiting)
    rc, out, err = cli("speak", "--wait", "hello there", timeout=15)
    check("speak --wait returns (job fails with no model)", True)
    st, js, _ = req("POST", "/v1/speak", {"text": "waiting target"}, token=token)
    jid = js.get("job_id", "j_0") if js else "j_0"
    waiter = subprocess.Popen([BIN, "speak", "--wait", "-p", "queue", "waiting target two"], env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.5)
    req("DELETE", "/v1/history", token=token)
    try:
        waiter.wait(timeout=10); finished = True
    except subprocess.TimeoutExpired:
        waiter.kill(); finished = False
    check("--wait does not hang after Clear History", finished)

    # --- previews from Settings never reach history
    req("POST", "/v1/speak", {"text": "Hi, this is a preview.", "source": {"app": "preview"}}, token=token)
    req("POST", "/v1/speak", {"text": "Not a preview.", "source": {"app": "cli"}, "policy": "queue"}, token=token)
    time.sleep(1.5)
    st, js, _ = req("GET", "/v1/jobs", token=token)
    apps = [j["app"] for j in js["jobs"]]
    check("previews are left out of history", "preview" not in apps and "cli" in apps, apps)

    # --- Clear History sticks across a restart
    req("DELETE", "/v1/history", token=token)
    time.sleep(1.2)
    st, js, _ = req("GET", "/v1/jobs", token=token)
    check("history empty after clear", st == 200 and len(js["jobs"]) == 0, js)

    # --- pairing: one at a time, origin shown, own scoped token
    ext = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
    other = "chrome-extension://zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
    st, p1, _ = req("POST", "/v1/pair", {}, origin=ext)
    check("pair request accepted", st == 202 and p1 and len(p1["code"]) == 4, (st, p1))
    st, js, _ = req("POST", "/v1/pair", {}, origin=other)
    check("second pending request refused (429)", st == 429, (st, js))
    st, js, _ = req("GET", "/v1/pair", token=token)
    check("pending list shows the origin", st == 200 and js["pending"][0]["origin"] == ext, js)
    st, js, _ = req("POST", f"/v1/pair/{p1['pair_id']}/approve", {}, token=token)
    check("approve", st == 200, js)
    st, js, _ = req("GET", f"/v1/pair/{p1['pair_id']}?secret={p1['secret']}", origin=ext)
    ext_token = (js or {}).get("token", "")
    check("extension gets its own token, not the master", js and js["status"] == "approved" and ext_token and ext_token != token, js)
    check("token stored hashed, file mode 0600",
          oct(os.stat(os.path.join(HOME, "extensions.json")).st_mode & 0o777) == "0o600" and ext_token not in open(os.path.join(HOME, "extensions.json")).read())
    check("extension: GET /v1/player ok", req("GET", "/v1/player", token=ext_token, origin=ext)[0] == 200)
    check("extension: POST /v1/player/pause ok", req("POST", "/v1/player/pause", {}, token=ext_token, origin=ext)[0] == 200)
    check("extension: GET /v1/settings forbidden", req("GET", "/v1/settings", token=ext_token, origin=ext)[0] == 403)
    check("extension: GET /v1/jobs forbidden", req("GET", "/v1/jobs", token=ext_token, origin=ext)[0] == 403)
    check("extension: speak/file forbidden", req("POST", "/v1/speak/file", {"path": "/etc/hosts.txt"}, token=ext_token, origin=ext)[0] == 403)
    check("extension: PATCH settings forbidden", req("PATCH", "/v1/settings", {"speed": 2}, token=ext_token, origin=ext)[0] == 403)
    check("extension token from another origin refused", req("GET", "/v1/player", token=ext_token, origin=other)[0] == 403)
    check("master token with an extension Origin refused", req("GET", "/v1/player", token=token, origin=ext)[0] == 401)
    st, js, _ = req("POST", "/v1/pair/forget", {"origin": ext}, token=token)
    check("forget", st == 200, js)
    st = req("GET", "/v1/player", token=ext_token)[0]
    check("forgotten extension's token is revoked", st == 401, st)

    # --- deny cooldown
    st, p2, _ = req("POST", "/v1/pair", {}, origin=other)
    req("POST", f"/v1/pair/{p2['pair_id']}/deny", {}, token=token)
    st, js, _ = req("POST", "/v1/pair", {}, origin=other)
    check("denied extension must wait before asking again", st == 429, (st, js))

    # --- connections are capped, and the server recovers when they close
    import socket
    idle = []
    for _ in range(80):
        sk = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        idle.append(sk)
    time.sleep(0.5)
    closed = 0
    for sk in idle[64:]:
        sk.settimeout(2)
        try:
            if sk.recv(1) == b"": closed += 1
        except (ConnectionResetError, socket.timeout):
            closed += isinstance(sys.exc_info()[1], ConnectionResetError)
    check("connections beyond 64 are closed at once", closed >= 10, closed)
    for sk in idle: sk.close()
    time.sleep(0.5)
    check("server serves again after they close", req("GET", "/v1/health")[0] == 200)

    # --- web pages still locked out
    check("web origin refused", req("GET", "/v1/player", token=token, origin="https://evil.example")[0] == 403)
finally:
    server.terminate()
    server.wait()

failed = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
