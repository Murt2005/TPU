"""A browser chat with Qwen2.5-0.5B running on the core: a small local web app
(standard library only) that tokenizes your prompt, sends it to qwen-run --serve,
and streams the reply back token by token.

    .venv/bin/python software/qwen/chat.py --board /dev/cu.usbserial-<id>0
    .venv/bin/python software/qwen/chat.py --board ... --load      # weights not in DDR3 yet (~90 s)
    .venv/bin/python software/qwen/chat.py --ref                  # no board: the exact C reference on the Mac

then open http://localhost:8000. It needs the standard library and pyserial (the
repo's .venv), not PyTorch. --board needs the board booted through
u-boot.scr (mem=256M, the port live) and /mnt/boot/qwen/ holding qwen-run,
qwen-host.bin, qwen-vocab.bin and qwen-ddr.bin. The base model continues text
rather than following instructions; chat mode frames each turn as
"User: ... / Assistant:" and stops a reply where the model starts the user's next line.
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host"))
from tokenizer import Tokenizer  # noqa: E402


class LocalBackend:
    """qwen-run on the Mac, over pipes (the ref core, or the Verilator core)"""

    def __init__(self, core):
        run = os.path.join(HERE, "runtime", "qwen-run")
        self.name = f"Mac, {core.split(':')[0]} core"
        self.p = subprocess.Popen([run, "--tables", os.path.join(HERE, "out"), "--core", core, "--serve"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, bufsize=1)
        assert self.p.stdout.readline().strip() == "READY"

    def send(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()

    def readline(self):
        return self.p.stdout.readline()


class BoardBackend:
    """qwen-run --core mmio on the DE1-SoC, over its console"""

    def __init__(self, port, load):
        from tpu.isa_device import BoardConsole
        self.name = "DE1-SoC, 8x8 core at 50 MHz"
        self.console = BoardConsole(port)
        core = "mmio:qwen-ddr.bin" if load else "mmio"
        self.console.launch(f"cd /mnt/boot/qwen; stty raw -echo; ./qwen-run --tables . --core {core} --serve; "
                            f"stty sane; cd /", timeout=10)
        self.s = self.console._s
        self.s.timeout = 1.0
        end = time.time() + (300 if load else 60)
        while time.time() < end:
            line = self.readline()
            if line.strip() == "READY":
                return
            if line.strip():
                print(f"board: {line.strip()}")
        raise RuntimeError("qwen-run --serve never said READY")

    def send(self, line):
        self.s.write((line + "\n").encode())

    def readline(self):
        out = b""
        while not out.endswith(b"\n"):
            chunk = self.s.read(1)
            if not chunk:
                if out:
                    continue
                return ""
            out += chunk
        return out.decode(errors="replace")


class Chat:
    def __init__(self, backend, tokenizer):
        self.backend, self.tok = backend, tokenizer
        self.lock = threading.Lock()

    def stream(self, prompt, max_tokens, stop=None):
        """yields text pieces as tokens arrive, then a dict of stats"""
        ids = self.tok.encode(prompt)
        with self.lock:
            self.backend.send(f"G {max_tokens} " + ",".join(map(str, ids)))
            made, shown, first_at, t0, stopped = [], "", None, time.time(), False
            while True:
                line = self.backend.readline()
                if not line:
                    if time.time() - t0 > 600:
                        raise RuntimeError("no reply")
                    continue
                kind, *rest = line.split()
                if kind == "T":
                    made.append(int(rest[0]))
                    first_at = first_at or time.time()
                    text = self.tok.decode(made)
                    if text.endswith("�"):       # half a UTF-8 character: wait for the rest
                        continue
                    if stop and not stopped:
                        cut = text.find(stop)
                        if cut >= 0:
                            text, stopped = text[:cut], True
                    if not stopped or len(text) > len(shown):
                        if text.startswith(shown) and len(text) > len(shown):
                            yield text[len(shown):]
                            shown = text
                elif kind == "E":
                    count, prompt_s, gen_s = int(rest[0]), float(rest[1]), float(rest[2])
                    yield dict(tokens=count, prompt_tokens=len(ids), prompt_seconds=prompt_s,
                               generate_seconds=gen_s,
                               tokens_per_second=(count - 1) / gen_s if count > 1 and gen_s > 0 else 0.0,
                               backend=self.backend.name)
                    return


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Qwen on the TPU</title>
<style>
:root { --bg:#f6f6f4; --panel:#fff; --text:#1d1d1b; --muted:#6b6b66; --line:#e2e1dc; --user:#e9eefb; --accent:#3757d6; }
@media (prefers-color-scheme: dark) { :root { --bg:#161615; --panel:#1f1f1d; --text:#ecebe6; --muted:#9a9993; --line:#33332f; --user:#232a40; --accent:#7f97ff; } }
* { box-sizing:border-box } body { margin:0; background:var(--bg); color:var(--text); font:15px/1.5 -apple-system, system-ui, sans-serif; }
main { max-width:820px; margin:0 auto; padding:16px; display:flex; flex-direction:column; height:100vh; }
header { display:flex; align-items:baseline; gap:12px; flex-wrap:wrap; padding-bottom:10px; border-bottom:1px solid var(--line); }
h1 { font-size:17px; margin:0 } #backend { color:var(--muted); font-size:13px }
#log { flex:1; overflow-y:auto; padding:16px 0; display:flex; flex-direction:column; gap:12px; }
.msg { padding:10px 14px; border-radius:10px; white-space:pre-wrap; max-width:90%; }
.user { background:var(--user); align-self:flex-end } .bot { background:var(--panel); border:1px solid var(--line); align-self:flex-start }
.stats { color:var(--muted); font-size:12px; margin-top:6px }
form { display:flex; gap:8px; align-items:flex-end; border-top:1px solid var(--line); padding-top:10px; flex-wrap:wrap }
textarea { flex:1; min-width:220px; resize:vertical; min-height:44px; padding:10px; border-radius:8px; border:1px solid var(--line); background:var(--panel); color:var(--text); font:inherit }
button, select, input { font:inherit; border-radius:8px; border:1px solid var(--line); background:var(--panel); color:var(--text); padding:9px 12px }
button[type=submit] { background:var(--accent); color:#fff; border-color:var(--accent) } button:disabled { opacity:.5 }
.controls { display:flex; gap:8px; align-items:center; color:var(--muted); font-size:13px } .controls input { width:70px; padding:6px }
</style></head><body><main>
<header><h1>Qwen2.5-0.5B on the TPU</h1><span id="backend"></span></header>
<div id="log"></div>
<form id="f">
  <textarea id="prompt" placeholder="Ask something, or start a text for the model to continue" rows="2"></textarea>
  <div class="controls">
    <select id="mode" title="chat keeps the conversation; complete continues your text as-is">
      <option value="chat">Chat</option><option value="complete">Complete</option></select>
    <label>max <input id="max" type="number" min="1" max="512" value="48"></label>
    <button type="button" id="clear">Clear</button>
    <button type="submit" id="send">Send</button>
  </div>
</form>
</main>
<script>
const log = document.getElementById('log'), form = document.getElementById('f'), promptBox = document.getElementById('prompt');
const send = document.getElementById('send'); let history = [];
fetch('/info').then(r => r.json()).then(i => document.getElementById('backend').textContent = i.backend);
function bubble(cls, text) { const d = document.createElement('div'); d.className = 'msg ' + cls; d.textContent = text;
  log.appendChild(d); log.scrollTop = log.scrollHeight; return d; }
document.getElementById('clear').onclick = () => { history = []; log.innerHTML = ''; };
promptBox.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); form.requestSubmit(); } });
form.onsubmit = e => {
  e.preventDefault(); const text = promptBox.value.trim(); if (!text || send.disabled) return;
  const mode = document.getElementById('mode').value, max = document.getElementById('max').value;
  bubble('user', text); promptBox.value = ''; send.disabled = true;
  let prompt = text, stop = '';
  if (mode === 'chat') { history.push('User: ' + text); prompt = history.join('\n') + '\nAssistant:'; stop = '\nUser'; }
  const bot = bubble('bot', ''); let reply = '';
  const es = new EventSource('/generate?' + new URLSearchParams({prompt, max, stop}));
  es.onmessage = ev => { const m = JSON.parse(ev.data);
    if (m.text !== undefined) { reply += m.text; bot.textContent = reply; log.scrollTop = log.scrollHeight; }
    if (m.done) { es.close(); send.disabled = false;
      if (mode === 'chat') history.push('Assistant:' + reply);
      const s = document.createElement('div'); s.className = 'stats';
      s.textContent = `${m.done.prompt_tokens}-token prompt in ${m.done.prompt_seconds.toFixed(1)} s · ${m.done.tokens} tokens at ${m.done.tokens_per_second.toFixed(2)} tokens/s`;
      bot.appendChild(s); }
    if (m.error) { es.close(); send.disabled = false; bot.textContent = 'error: ' + m.error; } };
  es.onerror = () => { es.close(); send.disabled = false; };
};
</script></body></html>
"""


def make_handler(chat):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            if url.path == "/":
                body = PAGE.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif url.path == "/info":
                body = json.dumps(dict(backend=chat.backend.name)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
            elif url.path == "/generate":
                q = urllib.parse.parse_qs(url.query)
                prompt, stop = q.get("prompt", [""])[0], q.get("stop", [""])[0] or None
                max_tokens = max(1, min(512, int(q.get("max", ["48"])[0])))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                try:
                    for piece in chat.stream(prompt, max_tokens, stop):
                        msg = dict(done=piece) if isinstance(piece, dict) else dict(text=piece)
                        self.wfile.write(f"data: {json.dumps(msg)}\n\n".encode())
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as e:      # the page shows it
                    self.wfile.write(f"data: {json.dumps(dict(error=str(e)))}\n\n".encode())
            else:
                self.send_error(404)
    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--board", metavar="PORT", help="the DE1-SoC's HPS console")
    where.add_argument("--ref", action="store_true", help="the exact C reference core on the Mac")
    where.add_argument("--sim", metavar="TB_ISA", help="the Verilator core (slow: ~36 s a token)")
    ap.add_argument("--load", action="store_true", help="with --board: load the weights into DDR3 first")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    image = os.path.join(HERE, "out", "qwen-ddr.bin")
    if args.board:
        backend = BoardBackend(args.board, args.load)
    elif args.sim:
        backend = LocalBackend(f"sim:{args.sim}:{image}")
    else:
        backend = LocalBackend(f"ref:{image}")
    chat = Chat(backend, Tokenizer.from_dir(os.path.join(HERE, "model")))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(chat))
    url = f"http://localhost:{args.port}"
    print(f"{backend.name}: {url}", flush=True)
    if not args.no_browser:
        webbrowser.open(url)
    server.serve_forever()


if __name__ == "__main__":
    main()
