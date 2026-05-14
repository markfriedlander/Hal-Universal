#!/usr/bin/env python3
"""
hal_test.py — Hal Universal test runner and control script.

HTTP mode (when tests/.hal_api_config.json exists):
  Connects directly to LocalAPIServer on port 8766. Fully synchronous and reactive.
  (Hal owns 8766 in the Mark Friedlander app family; Posey owns 8765. Each app
  has its own port so multiple CC instances can test in parallel without
  colliding on the simulator or the Mac.)

File mode (fallback, no config):
  Polls output_latest.json via mtime. Slower, for when HTTP is unavailable.

Usage:
  python3 tests/hal_test.py autodiscover               # read ip:port:token from clipboard (app copies on start)
  python3 tests/hal_test.py setup <ip> 8766 <token>   # one-time manual config
  python3 tests/hal_test.py reset                      # nuclear reset
  python3 tests/hal_test.py new                        # new thread (keep memory)
  python3 tests/hal_test.py turn "Hello"               # single turn
  python3 tests/hal_test.py cmd SET_TEMPERATURE:0.8    # any command
  python3 tests/hal_test.py state                      # print state
  python3 tests/hal_test.py run tests/convos/test.txt  # scripted file
  python3 tests/hal_test.py chat                       # interactive REPL

Model management (requires LocalAPIServer running):
  python3 tests/hal_test.py list_models                # list all models
  python3 tests/hal_test.py download <model_id>        # start download
  python3 tests/hal_test.py model_status <model_id>    # poll download status
  python3 tests/hal_test.py switch_model <model_id>    # switch active model
  python3 tests/hal_test.py delete_model <model_id>    # delete downloaded model
  python3 tests/hal_test.py cancel_download <model_id> # cancel in-progress download
  python3 tests/hal_test.py current_model              # show active model

Thread management:
  python3 tests/hal_test.py threads                    # list all threads
  python3 tests/hal_test.py switch_thread <id>         # switch to existing thread
  python3 tests/hal_test.py messages                   # print messages in current thread (from DB)
  python3 tests/hal_test.py memory_stats               # DB row counts
  python3 tests/hal_test.py reflections                # recent self-reflection entries

UI observation (what's on screen vs what's in the DB):
  python3 tests/hal_test.py ui_state                   # current view, sheets, typing state, error banners, input draft
  python3 tests/hal_test.py rendered_messages          # messages bound to chat view (vm.messages, includes partials)
  python3 tests/hal_test.py logs [N]                   # last N debug log entries (default 200) - HALDEBUG-* etc.
  python3 tests/hal_test.py clear_logs                 # wipe the in-process log buffer

Document management:
  python3 tests/hal_test.py list_documents             # list imported documents
  python3 tests/hal_test.py import_document <path>     # import a file into RAG
  python3 tests/hal_test.py delete_document <source_id># remove document from RAG

Watch round-trip (without paired hardware):
  python3 tests/hal_test.py simulate_watch "Hello"     # exercise the full WCSession path; response returned in API body

Scripted file format:
  # comment lines are ignored
  > This is a user turn sent to Hal
  CMD SET_TEMPERATURE:0.5
  WAIT 2        # sleep N seconds
  ASSERT response contains "some phrase"  # (not yet enforced, just logged)
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error

# ─── Config ─────────────────────────────────────────────────────────────────

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE  = os.path.join(SCRIPT_DIR, ".hal_api_config.json")

HAL_TEST_DIR = os.path.expanduser("~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Documents/hal_test")
OUTPUT_FILE  = os.path.join(HAL_TEST_DIR, "output_latest.json")
INPUT_FILE   = os.path.join(HAL_TEST_DIR, "input.txt")
COMMANDS_FILE = os.path.join(HAL_TEST_DIR, "commands.txt")

FILE_POLL_INTERVAL = 2.0  # seconds
FILE_POLL_TIMEOUT  = 90.0  # seconds


# ─── HTTP Client ─────────────────────────────────────────────────────────────

def load_config():
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            return json.load(f)
    return None


def http_post(path, payload, config, timeout=600):
    """POST JSON to Hal's LocalAPIServer. Returns parsed JSON response."""
    url = f"http://{config['host']}:{config['port']}{path}"
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {config['token']}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            return json.loads(body)
        except Exception:
            return {"error": f"HTTP {e.code}: {body}"}
    except Exception as e:
        return {"error": str(e)}


def http_get(path, config, timeout=30):
    """GET from Hal's LocalAPIServer. Returns parsed JSON response."""
    url = f"http://{config['host']}:{config['port']}{path}"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {config['token']}"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        return {"error": str(e)}


def send_chat(message, config):
    """Send a chat message and return the full diagnostic response."""
    print(f"  >> {message}")
    result = http_post("/chat", {"message": message}, config, timeout=300)
    if "error" in result:
        print(f"  ERROR: {result['error']}")
    elif "response" in result:
        resp = result.get("response", "")
        model = result.get("model", "?")
        elapsed = result.get("thinkingDuration", 0)
        print(f"  [{model} {elapsed:.1f}s] {resp[:300]}{'...' if len(resp) > 300 else ''}")
    return result


def send_command(cmd, config):
    """Send a command and return the result."""
    result = http_post("/command", {"command": cmd}, config)
    if "error" in result:
        print(f"  CMD ERROR: {result['error']}")
    else:
        print(f"  CMD OK: {json.dumps(result, indent=2)[:300]}")
    return result


def get_state(config):
    """Fetch and print current state."""
    result = http_get("/state", config)
    print(json.dumps(result, indent=2))
    return result


# ─── File Mode (fallback) ───────────────────────────────────────────────────

def file_send_turn(message):
    """File mode: write to input.txt and poll output_latest.json."""
    if not os.path.exists(INPUT_FILE):
        print(f"ERROR: input.txt not found at {INPUT_FILE}")
        print("Enable the test console in Hal's Power User settings first.")
        sys.exit(1)

    mtime_before = os.path.getmtime(OUTPUT_FILE) if os.path.exists(OUTPUT_FILE) else 0

    print(f"  >> {message}")
    with open(INPUT_FILE, "w") as f:
        f.write(message)

    start = time.time()
    while time.time() - start < FILE_POLL_TIMEOUT:
        time.sleep(FILE_POLL_INTERVAL)
        if not os.path.exists(OUTPUT_FILE):
            continue
        mtime_after = os.path.getmtime(OUTPUT_FILE)
        if mtime_after > mtime_before:
            with open(OUTPUT_FILE) as f:
                result = json.load(f)
            resp = result.get("response", "")
            model = result.get("model", "?")
            elapsed = result.get("thinkingDuration", 0)
            print(f"  [{model} {elapsed:.1f}s] {resp[:300]}{'...' if len(resp) > 300 else ''}")
            return result

    print(f"  TIMEOUT after {FILE_POLL_TIMEOUT}s — no response detected")
    return None


def file_send_command(cmd):
    """File mode: write to commands.txt."""
    if not os.path.exists(COMMANDS_FILE):
        print(f"ERROR: commands.txt not found at {COMMANDS_FILE}")
        sys.exit(1)
    with open(COMMANDS_FILE, "w") as f:
        f.write(cmd)
    time.sleep(0.5)
    print(f"  CMD sent: {cmd}")


# ─── Script Runner ───────────────────────────────────────────────────────────

def run_script(path, config):
    """Run a scripted conversation file."""
    if not os.path.exists(path):
        print(f"ERROR: Script not found: {path}")
        sys.exit(1)

    with open(path) as f:
        lines = f.readlines()

    turn_num = 0
    for raw_line in lines:
        line = raw_line.strip()

        if not line or line.startswith("#"):
            continue

        if line.startswith("> "):
            message = line[2:]
            turn_num += 1
            print(f"\n[Turn {turn_num}]")
            if config:
                send_chat(message, config)
            else:
                file_send_turn(message)

        elif line.startswith("CMD "):
            cmd = line[4:]
            if config:
                send_command(cmd, config)
            else:
                file_send_command(cmd)

        elif line.startswith("WAIT "):
            secs = float(line.split()[1])
            print(f"  Waiting {secs}s...")
            time.sleep(secs)

        elif line.startswith("ASSERT "):
            # Soft assertion — logged only
            print(f"  [ASSERT] {line[7:]}")

        else:
            print(f"  [SKIP] Unknown line: {line[:60]}")


# ─── Interactive REPL ────────────────────────────────────────────────────────

def chat_repl(config):
    """Interactive REPL that reads each response before sending the next."""
    print("Hal chat REPL. Type your message (Enter to send), CMD <cmd> for commands, or 'quit' to exit.")
    print("-" * 60)
    turn_num = 0
    while True:
        try:
            user_input = input("\nYou: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nExiting.")
            break

        if not user_input:
            continue
        if user_input.lower() in ("quit", "exit", "q"):
            break
        if user_input.upper().startswith("CMD "):
            send_command(user_input[4:], config)
            continue

        turn_num += 1
        result = send_chat(user_input, config)
        if result and "error" not in result:
            # Pretty-print the response
            resp = result.get("response", "")
            model = result.get("model", "?")
            elapsed = result.get("thinkingDuration", 0)
            print(f"\nHal [{model}, {elapsed:.1f}s]:\n  {resp}")


# ─── Model Management ────────────────────────────────────────────────────────

def cmd_list_models(config):
    result = send_command("LIST_MODELS", config)
    models = result.get("models", [])
    if not models:
        print("No models in catalog (catalog may still be loading).")
        return
    print(f"\n{'ID':<55} {'Downloaded':>10} {'Active':>6} {'Size GB':>8}")
    print("-" * 85)
    for m in models:
        size = f"{m['sizeGB']:.1f}" if m.get('sizeGB') is not None else "?"
        dl   = "✓" if m.get('downloaded') else " "
        act  = "◀" if m.get('active') else " "
        print(f"{m['id']:<55} {dl:>10} {act:>6} {size:>8}")


def cmd_download(model_id, config):
    result = send_command(f"DOWNLOAD_MODEL:{model_id}", config)
    print(f"Download initiated: {result}")
    print("Poll status with: python3 tests/hal_test.py model_status <model_id>")


def cmd_model_status(model_id, config):
    """Poll download status until complete (Ctrl-C to stop)."""
    print(f"Polling status for: {model_id}")
    while True:
        result = send_command(f"MODEL_STATUS:{model_id}", config)
        is_dl    = result.get("isDownloading", False)
        done     = result.get("isDownloaded", False)
        progress = float(result.get("progress", 0))
        error    = result.get("error")

        bar_len = 40
        filled  = int(progress * bar_len)
        bar     = "█" * filled + "░" * (bar_len - filled)
        print(f"\r  [{bar}] {progress*100:.1f}%  ", end="", flush=True)

        if error and error != "null":
            print(f"\nERROR: {error}")
            break
        if done and not is_dl:
            print(f"\nDownload complete.")
            break
        if not is_dl and not done:
            print(f"\nNot downloading and not complete. status: {result}")
            break
        time.sleep(2.0)


def cmd_switch_model(model_id, config):
    result = send_command(f"SWITCH_MODEL:{model_id}", config)
    print(f"Switch result: {result}")


def cmd_delete_model(model_id, config):
    confirm = input(f"Delete {model_id}? This removes it from disk. [y/N] ").strip().lower()
    if confirm != "y":
        print("Cancelled.")
        return
    result = send_command(f"DELETE_MODEL:{model_id}", config)
    print(f"Delete result: {result}")


def cmd_current_model(config):
    result = send_command("CURRENT_MODEL", config)
    print(f"Active model: {result.get('modelID', '?')} ({result.get('displayName', '?')})")


def cmd_cancel_download(model_id, config):
    result = send_command(f"CANCEL_DOWNLOAD:{model_id}", config)
    print(f"Cancel result: {result}")


# ─── Thread Management ───────────────────────────────────────────────────────

def cmd_threads(config):
    result = send_command("GET_THREADS", config)
    threads = result.get("threads", [])
    if not threads:
        print("No threads found.")
        return
    print(f"\n{'ID':<38} {'Active':>6}  Title")
    print("-" * 70)
    for t in threads:
        act = "◀" if t.get("active") else " "
        print(f"{t['id']:<38} {act:>6}  {t.get('title', '?')}")


def cmd_switch_thread(thread_id, config):
    result = send_command(f"SWITCH_THREAD:{thread_id}", config)
    if "error" in result:
        print(f"Error: {result['error']}")
    else:
        print(f"Switched to thread {thread_id[:8]}... ({result.get('messageCount', '?')} messages)")


def cmd_messages(config):
    result = send_command("GET_MESSAGES", config)
    msgs = result.get("messages", [])
    conv = result.get("conversationId", "?")
    print(f"\nThread: {conv[:8]}...  ({result.get('messageCount', 0)} messages)\n")
    for m in msgs:
        role = m.get("role", "?").upper()
        ts   = m.get("timestamp", 0)
        text = m.get("content", "")
        trunc = " [truncated]" if m.get("truncated") else ""
        print(f"[{role}] {text}{trunc}\n")


def cmd_memory_stats(config):
    result = send_command("GET_MEMORY_STATS", config)
    print(json.dumps(result, indent=2))


def cmd_ui_state(config):
    """What the user actually sees on screen, including which sheet is presented,
    typing state, error banners, input-field draft, and partial streaming content."""
    result = send_command("GET_UI_STATE", config)
    print(json.dumps(result, indent=2))


def cmd_logs(config, limit=200):
    """Recent in-process log entries captured by RuntimeLog. Includes HALDEBUG-*
    lines from the chat path (TTFT, token rate, generation stop reason, etc.).
    Use to diagnose MLX/AFM behaviour without device-console access."""
    cmd = "GET_LOGS" if limit == 200 else f"GET_LOGS:{limit}"
    result = send_command(cmd, config)
    entries = result.get("logs", [])
    count = result.get("count", 0)
    print(f"\n{count} log entries:\n")
    for line in entries:
        print(line)


def cmd_clear_logs(config):
    """Wipe the runtime log buffer (e.g. before running a focused test)."""
    result = send_command("CLEAR_LOGS", config)
    print(json.dumps(result, indent=2))


def cmd_rendered_messages(config):
    """Messages currently bound to the chat view's ForEach (vm.messages), distinct
    from GET_MESSAGES which reads from the SQLite memoryStore. Use this to see
    in-flight partial messages and detect DB/UI drift."""
    result = send_command("GET_RENDERED_MESSAGES", config)
    msgs = result.get("messages", [])
    count = result.get("renderedMessageCount", 0)
    cid = result.get("conversationId", "?")
    print(f"Rendered in thread {cid[:8]}...  ({count} messages)\n")
    for m in msgs:
        role = m.get("role", "?").upper()
        partial = " (PARTIAL)" if m.get("isPartial") else ""
        recorded = m.get("recordedByModel", "?")
        turn = m.get("turnNumber", "?")
        text = m.get("content", "")
        trunc = " [truncated]" if m.get("truncated") else ""
        print(f"[{role}{partial}  turn={turn}  by={recorded}] {text}{trunc}\n")


def cmd_reflections(config):
    result = send_command("GET_REFLECTIONS", config)
    entries = result.get("reflections", [])
    total   = result.get("count", 0)
    print(f"\n{total} total reflections (showing up to 20):\n")
    for r in entries:
        rtype = "Practical" if r.get("type") == 1 else "Existential"
        print(f"[{rtype} @ turn {r.get('turn', '?')}]  {r.get('text', '')}\n")


# ─── Document Management ─────────────────────────────────────────────────────

def cmd_list_documents(config):
    result = send_command("LIST_DOCUMENTS", config)
    docs = result.get("documents", [])
    total = result.get("count", 0)
    if total == 0:
        print("No documents imported.")
        return
    print(f"\n{total} document(s):\n")
    print(f"{'Source ID':<38} {'Chunks':>6}  Name")
    print("-" * 70)
    for d in docs:
        print(f"{d['sourceID']:<38} {d.get('chunks', '?'):>6}  {d.get('name', '?')}")


def cmd_import_document(path, config):
    abs_path = os.path.abspath(path)
    if not os.path.exists(abs_path):
        print(f"File not found: {abs_path}")
        return
    print(f"Importing: {abs_path}")
    result = send_command(f"IMPORT_DOCUMENT:{abs_path}", config)
    print(f"Result: {result}")


def cmd_delete_document(source_id, config):
    confirm = input(f"Delete document {source_id[:12]}...? This removes it from RAG. [y/N] ").strip().lower()
    if confirm != "y":
        print("Cancelled.")
        return
    result = send_command(f"DELETE_DOCUMENT:{source_id}", config)
    print(f"Delete result: {result}")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(0)

    subcommand = args[0].lower()

    # Setup: save config (does not require existing config)
    if subcommand == "setup":
        if len(args) < 4:
            print("Usage: hal_test.py setup <ip> <port> <token>")
            sys.exit(1)
        config = {"host": args[1], "port": int(args[2]), "token": args[3]}
        with open(CONFIG_FILE, "w") as f:
            json.dump(config, f, indent=2)
        print(f"Config saved to {CONFIG_FILE}")
        print(f"Testing connection...")
        result = http_get("/state", config)
        if "error" in result:
            print(f"Connection failed: {result['error']}")
            print("Make sure the app is running and Developer API is enabled in Settings > Power User.")
        else:
            print("Connection OK!")
            print(json.dumps(result, indent=2))
        return

    # Autodiscover: read ip:port:token from clipboard (copied by app on start)
    if subcommand == "autodiscover":
        import subprocess
        clipboard = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout.strip()
        parts = clipboard.split(":")
        if len(parts) != 3:
            print(f"ERROR: Clipboard does not contain ip:port:token format.")
            print(f"Clipboard contents: {clipboard!r}")
            sys.exit(1)
        ip, port, token = parts[0], parts[1], parts[2]
        config = {"host": ip, "port": int(port), "token": token}
        with open(CONFIG_FILE, "w") as f:
            json.dump(config, f, indent=2)
        print(f"Discovered: {ip}:{port}")
        print(f"Testing connection...")
        result = http_get("/state", config)
        if "error" in result:
            print(f"Connection failed: {result['error']}")
        else:
            print("Connection OK!")
            print(json.dumps(result, indent=2))
        return

    config = load_config()

    if subcommand == "reset":
        if config:
            send_command("NUCLEAR_RESET", config)
        else:
            file_send_command("NUCLEAR_RESET")

    elif subcommand == "new":
        if config:
            send_command("NEW_THREAD", config)
        else:
            file_send_command("NEW_THREAD")

    elif subcommand == "turn":
        if len(args) < 2:
            print("Usage: hal_test.py turn <message>")
            sys.exit(1)
        message = " ".join(args[1:])
        if config:
            result = send_chat(message, config)
            if result and "response" in result:
                print(f"\nFull response:\n{result['response']}")
        else:
            file_send_turn(message)

    elif subcommand == "simulate_watch":
        # Run the full Watch round-trip locally — exercises the same
        # ChatViewModel.processWatchIncomingMessage entrypoint that real
        # WCSession deliveries use. Returns the assistant reply in the
        # API response, and pushes to the Watch via WCSession (no-op if
        # no Watch is paired/reachable, but the chat pipeline still ran).
        if len(args) < 2:
            print("Usage: hal_test.py simulate_watch <message>")
            sys.exit(1)
        message = " ".join(args[1:])
        if config:
            send_command(f"SIMULATE_WATCH_MESSAGE:{message}", config)
        else:
            file_send_command(f"SIMULATE_WATCH_MESSAGE:{message}")

    elif subcommand == "cmd":
        if len(args) < 2:
            print("Usage: hal_test.py cmd <COMMAND>")
            sys.exit(1)
        cmd = " ".join(args[1:])
        if config:
            send_command(cmd, config)
        else:
            file_send_command(cmd)

    elif subcommand == "state":
        if config:
            get_state(config)
        else:
            if os.path.exists(OUTPUT_FILE):
                with open(OUTPUT_FILE) as f:
                    print(f.read())
            else:
                print("No output file found. Enable the test console in Hal.")

    elif subcommand == "run":
        if len(args) < 2:
            print("Usage: hal_test.py run <script.txt>")
            sys.exit(1)
        run_script(args[1], config)

    elif subcommand == "chat":
        if not config:
            print("ERROR: HTTP config required for interactive chat.")
            print("Run: python3 tests/hal_test.py setup <ip> 8765 <token>")
            sys.exit(1)
        chat_repl(config)

    # Model management commands
    elif subcommand == "list_models":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_list_models(config)

    elif subcommand == "download":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        if len(args) < 2:
            print("Usage: hal_test.py download <model_id>")
            sys.exit(1)
        cmd_download(args[1], config)

    elif subcommand == "model_status":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        if len(args) < 2:
            print("Usage: hal_test.py model_status <model_id>")
            sys.exit(1)
        cmd_model_status(args[1], config)

    elif subcommand == "switch_model":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        if len(args) < 2:
            print("Usage: hal_test.py switch_model <model_id>")
            sys.exit(1)
        cmd_switch_model(args[1], config)

    elif subcommand == "delete_model":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        if len(args) < 2:
            print("Usage: hal_test.py delete_model <model_id>")
            sys.exit(1)
        cmd_delete_model(args[1], config)

    elif subcommand == "current_model":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_current_model(config)

    elif subcommand == "cancel_download":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        if len(args) < 2:
            print("Usage: hal_test.py cancel_download <model_id>")
            sys.exit(1)
        cmd_cancel_download(args[1], config)

    # Thread management commands
    elif subcommand == "threads":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_threads(config)

    elif subcommand == "switch_thread":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        if len(args) < 2:
            print("Usage: hal_test.py switch_thread <thread_id>")
            sys.exit(1)
        cmd_switch_thread(args[1], config)

    elif subcommand == "messages":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_messages(config)

    elif subcommand == "memory_stats":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_memory_stats(config)

    elif subcommand == "ui_state":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_ui_state(config)

    elif subcommand == "logs":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        limit = int(args[1]) if len(args) > 1 else 200
        cmd_logs(config, limit=limit)

    elif subcommand == "clear_logs":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_clear_logs(config)

    elif subcommand == "rendered_messages":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_rendered_messages(config)

    elif subcommand == "reflections":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_reflections(config)

    # Document management commands
    elif subcommand == "list_documents":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        cmd_list_documents(config)

    elif subcommand == "import_document":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        if len(args) < 2:
            print("Usage: hal_test.py import_document <path>")
            sys.exit(1)
        cmd_import_document(args[1], config)

    elif subcommand == "delete_document":
        if not config:
            print("ERROR: HTTP config required. Run setup first.")
            sys.exit(1)
        if len(args) < 2:
            print("Usage: hal_test.py delete_document <source_id>")
            sys.exit(1)
        cmd_delete_document(args[1], config)

    else:
        print(f"Unknown subcommand: {subcommand}")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
