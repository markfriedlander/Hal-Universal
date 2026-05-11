#!/usr/bin/env python3
"""
hal_test.py — Hal LMC Test Runner
===================================
Single-file, zero-dependency test harness for Hal Universal.

TRANSPORT
---------
Two modes, auto-selected:

  HTTP mode  (preferred): Uses Hal's Local API Server — synchronous, reactive, no polling.
             Requires: "Developer API" toggle ON in Hal Settings > Advanced.
             Config stored in tests/.hal_api_config.json (write once with `setup` command).

  File mode  (fallback):  Legacy file-polling harness (input.txt / output_latest.json).
             Works when no HTTP config is present. Still reliable but adds latency per turn.

USAGE
-----
  # First-time HTTP setup (get IP/token from Hal Settings > Advanced > Developer API):
  python3 tests/hal_test.py setup <ip> <port> <token>

  # Reactive conversation — reads each response before sending next message:
  python3 tests/hal_test.py chat

  # Single turn:
  python3 tests/hal_test.py turn "Hello"

  # Nuclear reset:
  python3 tests/hal_test.py reset

  # New thread (keep memory + settings):
  python3 tests/hal_test.py new

  # Any harness command:
  python3 tests/hal_test.py cmd NUCLEAR_RESET
  python3 tests/hal_test.py cmd SET_TEMPERATURE:0.8

  # Print current state:
  python3 tests/hal_test.py state

  # Run a conversation file (scripted turns):
  python3 tests/hal_test.py run tests/conversations/quality_test.txt

CONVERSATION FILE FORMAT (.txt)
---------------------------------
  # Lines starting with # are comments — skipped
  CMD: NUCLEAR_RESET          <- Harness command (CMD: prefix)
  CMD: SET_TEMPERATURE:0.8    <- Any SET_* command works
  Hello, I'm new here.        <- Plain text = conversation turn
  My name is Mark.            <- Next turn (waits for prior response first)

HARNESS COMMANDS
-----------------
  NUCLEAR_RESET               — Wipe all data + reset settings + new thread
  NEW_THREAD                  — New conversation thread (keep memory + settings)
  RESET_THREAD                — Delete current thread + start fresh
  RESET_SETTINGS              — Reset all settings to defaults (keep conversations)
  GET_STATE                   — Return current settings state
  CLEAR_TEST_DATA             — Wipe conversations only (keep settings + documents)
  SET_MEMORY_DEPTH:<n>        — Set STM depth (clamped to model limit)
  SET_TEMPERATURE:<0.0-1.0>   — Set inference temperature
  SET_SELF_KNOWLEDGE:<true|false>    — Toggle self-knowledge injection
  SET_SIMILARITY_THRESHOLD:<0.0-1.0> — Set RAG relevance threshold
  SET_MAX_RAG_CHARS:<n>       — Set max RAG retrieval characters (min 200)
  SET_RAG_DEDUP:<0.0-1.0>    — Set cosine similarity dedup threshold
  SET_SYSTEM_PROMPT:<text>    — Session override (not persisted)
  SET_SYSTEM_PROMPT_STORED:<text> — Set stored system prompt (persisted)
  CLEAR_SYSTEM_PROMPT         — Clear session override

HTTP API ENDPOINTS (when Developer API is enabled in Hal)
----------------------------------------------------------
  POST /chat      {"message": "..."}          → full diagnostic JSON
  POST /command   {"command": "NUCLEAR_RESET"} → JSON result
  GET  /state                                  → settings state JSON
  All requests require: Authorization: Bearer <token>

FILE-MODE PATHS (legacy, auto-used when no HTTP config)
--------------------------------------------------------
  ~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Documents/hal_test/
    input.txt          — write turn text here
    commands.txt       — write harness commands here
    output_latest.json — most recent response
    state.json         — settings state
"""

import os
import sys
import time
import json
import http.client

# ─── Config ───────────────────────────────────────────────────────────────────

_SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
_CONFIG_FILE = os.path.join(_SCRIPT_DIR, ".hal_api_config.json")

_api_config: dict | None = None

def _load_config() -> dict | None:
    global _api_config
    if os.path.exists(_CONFIG_FILE):
        try:
            with open(_CONFIG_FILE) as f:
                _api_config = json.load(f)
        except Exception as e:
            print(f"  ⚠  Could not read {_CONFIG_FILE}: {e}")
    return _api_config

_load_config()

def _using_http() -> bool:
    return _api_config is not None

# ─── HTTP Transport ────────────────────────────────────────────────────────────

def _http(method: str, path: str, body: dict | None = None, timeout: int = 120) -> tuple[int, dict]:
    """Execute one HTTP request against Hal's Local API Server. Blocking."""
    cfg  = _api_config
    conn = http.client.HTTPConnection(cfg["host"], cfg["port"], timeout=timeout)
    hdrs = {
        "Authorization": f"Bearer {cfg['token']}",
        "Content-Type":  "application/json",
    }
    data = json.dumps(body).encode() if body else b""
    conn.request(method, path, body=data, headers=hdrs)
    resp = conn.getresponse()
    raw  = resp.read()
    conn.close()
    try:
        return resp.status, json.loads(raw)
    except Exception:
        return resp.status, {"raw": raw.decode("utf-8", errors="replace")}


def _http_turn(text: str, timeout: int = 120) -> tuple[str | None, dict | None]:
    """POST /chat — blocking until Hal responds."""
    status, data = _http("POST", "/chat", {"message": text}, timeout=timeout)
    if status == 200:
        return data.get("response", ""), data
    print(f"  ✗  HTTP {status}: {data.get('error', data)}")
    return None, None


def _http_command(cmd: str, timeout: int = 60) -> dict | None:
    """POST /command — blocking until command completes."""
    status, data = _http("POST", "/command", {"command": cmd}, timeout=timeout)
    if status != 200:
        print(f"  ✗  HTTP {status}: {data.get('error', data)}")
        return None
    return data


def _http_state() -> dict:
    """GET /state."""
    status, data = _http("GET", "/state", timeout=15)
    if status == 200:
        return data
    return {"error": f"HTTP {status}", "detail": data}

# ─── File Transport (legacy fallback) ─────────────────────────────────────────

_HAL_DIR      = os.path.expanduser(
    "~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Documents/hal_test"
)
_INPUT_FILE    = os.path.join(_HAL_DIR, "input.txt")
_COMMANDS_FILE = os.path.join(_HAL_DIR, "commands.txt")
_OUTPUT_LATEST = os.path.join(_HAL_DIR, "output_latest.json")
_STATE_FILE    = os.path.join(_HAL_DIR, "state.json")

_TURN_TIMEOUT  = 90   # seconds to wait for a response
_POLL_INTERVAL = 2    # seconds between mtime polls
_COMMAND_WAIT  = 4    # seconds after a regular command
_RESET_WAIT    = 8    # seconds after NUCLEAR_RESET


def _mtime(path: str) -> float:
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


def _file_command(cmd: str, wait: int | None = None) -> None:
    if wait is None:
        wait = _RESET_WAIT if "RESET" in cmd.upper() else _COMMAND_WAIT
    with open(_COMMANDS_FILE, "w") as f:
        f.write(cmd.strip())
    print(f"  ⚙  FILE-CMD: {cmd.strip()}  (waiting {wait}s)")
    time.sleep(wait)


def _file_turn(text: str, timeout: int = _TURN_TIMEOUT) -> tuple[str | None, dict | None]:
    before = _mtime(_OUTPUT_LATEST)
    with open(_INPUT_FILE, "w") as f:
        f.write(text.strip())
    elapsed = 0
    while elapsed < timeout:
        time.sleep(_POLL_INTERVAL)
        elapsed += _POLL_INTERVAL
        if _mtime(_OUTPUT_LATEST) != before:
            try:
                with open(_OUTPUT_LATEST) as f:
                    data = json.load(f)
                return data.get("response", ""), data
            except Exception as e:
                print(f"  ⚠  Could not parse output_latest.json: {e}")
                return None, None
    print(f"  ✗  TIMEOUT after {timeout}s — is Hal running? Is the test console enabled?")
    return None, None


def _file_state() -> dict:
    before = _mtime(_STATE_FILE)
    with open(_COMMANDS_FILE, "w") as f:
        f.write("GET_STATE")
    for _ in range(15):
        time.sleep(1)
        if _mtime(_STATE_FILE) != before:
            break
    try:
        with open(_STATE_FILE) as f:
            return json.load(f)
    except Exception as e:
        return {"error": str(e)}

# ─── Public API — transport-agnostic ─────────────────────────────────────────

def send_turn(text: str, timeout: int = 120) -> tuple[str | None, dict | None]:
    """
    Send a conversation turn and wait for Hal's response.
    Uses HTTP if configured, file-polling otherwise.
    Returns (response_text, output_data) or (None, None) on failure.
    """
    if _using_http():
        return _http_turn(text, timeout=timeout)
    return _file_turn(text, timeout=min(timeout, _TURN_TIMEOUT))


def send_command(cmd: str, wait: int | None = None) -> dict | None:
    """
    Send a harness command (e.g. NUCLEAR_RESET, SET_TEMPERATURE:0.8).
    HTTP mode: blocking, returns JSON result.
    File mode: writes file, waits fixed delay, returns None.
    """
    if _using_http():
        timeout = 30 if "RESET" not in cmd.upper() else 60
        print(f"  ⚙  CMD: {cmd.strip()}")
        return _http_command(cmd.strip(), timeout=timeout)
    _file_command(cmd, wait=wait)
    return None


def get_state() -> dict:
    """Return current Hal settings state."""
    if _using_http():
        return _http_state()
    return _file_state()

# ─── Higher-Level Operations ──────────────────────────────────────────────────

def reset() -> None:
    """Nuclear reset: wipe everything, start fresh."""
    print("Resetting Hal (nuclear)...")
    result = send_command("NUCLEAR_RESET")
    if result:
        deleted = result.get("threadsDeleted", "?")
        print(f"  Done. {deleted} thread(s) deleted. Hal is fresh.\n")
    else:
        print("  Done. Hal is fresh.\n")


def new_thread() -> None:
    """Start a new conversation thread (keep memory + settings)."""
    print("Starting new thread...")
    send_command("NEW_THREAD")
    print("  Done.\n")


def run_conversation(turns: list) -> list[dict]:
    """
    Execute a list of turns.
    Each item is either:
      - str: a conversation turn (waits for response before next)
      - ("CMD", "COMMAND_STRING"): a harness command
    Returns list of result dicts.
    """
    results = []
    for i, item in enumerate(turns, 1):
        if isinstance(item, tuple) and item[0] == "CMD":
            print(f"\n[CMD] {item[1]}")
            r = send_command(item[1])
            results.append({"type": "cmd", "cmd": item[1], "result": r})
        else:
            print(f"\n[T{i:02d}] YOU: {item}")
            response, data = send_turn(item)
            if response:
                preview = response[:300] + ("..." if len(response) > 300 else "")
                print(f"  HAL: {preview}")
                if data:
                    sections  = data.get("sectionsInjected", [])
                    rag_count = data.get("ragSnippetCount", len(data.get("memoryRetrieved", [])))
                    if sections or rag_count:
                        print(f"       [sections={sections}, rag={rag_count}]")
            else:
                print("  HAL: [NO RESPONSE — timeout or app not running]")
            results.append({
                "type":            "turn",
                "turn":            item,
                "response":        response,
                "sectionsInjected": data.get("sectionsInjected")  if data else None,
                "ragSnippetCount":  len(data.get("memoryRetrieved", [])) if data else None,
                "turn_number":      data.get("turn")              if data else None,
                "summaryActive":    data.get("injectedSummaryActive") if data else None,
            })
    return results


def run_file(path: str) -> list[dict]:
    """Parse and run a conversation file. Writes JSON report to <path>_report.json."""
    if not os.path.exists(path):
        print(f"File not found: {path}")
        sys.exit(1)

    turns = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.strip().startswith("#"):
                continue
            if line.strip().upper().startswith("CMD:"):
                turns.append(("CMD", line.strip()[4:].strip()))
            else:
                turns.append(line.strip())

    print(f"Running {len(turns)} items from: {path}\n")
    results = run_conversation(turns)

    report_path = path.rsplit(".", 1)[0] + "_report.json"
    with open(report_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\n✓ Report written: {report_path}")
    return results

# ─── CLI ──────────────────────────────────────────────────────────────────────

def main() -> None:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(0)

    verb = args[0].lower()

    # ── setup: write HTTP config ─────────────────────────────────────────────
    if verb == "setup":
        if len(args) < 4:
            print("Usage: hal_test.py setup <host> <port> <token>")
            print("  e.g. hal_test.py setup 127.0.0.1 8765 abc123token")
            print("\nGet host, port, and token from Hal Settings > Advanced > Developer API.")
            sys.exit(1)
        host, port, token = args[1], int(args[2]), args[3]
        cfg = {"host": host, "port": port, "token": token}
        with open(_CONFIG_FILE, "w") as f:
            json.dump(cfg, f, indent=2)
        print(f"✓ Config written to {_CONFIG_FILE}")
        print(f"  Host:  {host}")
        print(f"  Port:  {port}")
        print(f"  Token: {token[:8]}...")
        print(f"\nRun: python3 tests/hal_test.py turn \"Hello\" to verify.")

    # ── reset ────────────────────────────────────────────────────────────────
    elif verb == "reset":
        reset()

    # ── new ──────────────────────────────────────────────────────────────────
    elif verb == "new":
        new_thread()

    # ── turn ─────────────────────────────────────────────────────────────────
    elif verb == "turn":
        if len(args) < 2:
            print('Usage: hal_test.py turn "<message>"')
            sys.exit(1)
        text = " ".join(args[1:])
        response, data = send_turn(text)
        print(response or "[NO RESPONSE]")
        if data:
            sections  = data.get("sectionsInjected", [])
            rag_count = len(data.get("memoryRetrieved", []))
            print(f"\n[sections={sections}, rag={rag_count}]")

    # ── cmd ──────────────────────────────────────────────────────────────────
    elif verb == "cmd":
        if len(args) < 2:
            print("Usage: hal_test.py cmd <COMMAND>")
            sys.exit(1)
        result = send_command(" ".join(args[1:]))
        if result:
            print(json.dumps(result, indent=2))

    # ── state ────────────────────────────────────────────────────────────────
    elif verb == "state":
        print(json.dumps(get_state(), indent=2))

    # ── run ──────────────────────────────────────────────────────────────────
    elif verb == "run":
        if len(args) < 2:
            print("Usage: hal_test.py run <conversation_file.txt>")
            sys.exit(1)
        run_file(args[1])

    # ── chat — reactive REPL ─────────────────────────────────────────────────
    elif verb == "chat":
        mode = "HTTP" if _using_http() else "file-polling"
        print(f"Interactive chat with Hal [{mode} mode]. Ctrl+C or 'quit' to exit.\n")
        if not _using_http():
            print("  Tip: run 'hal_test.py setup <ip> <port> <token>' to enable faster HTTP mode.\n")
        while True:
            try:
                text = input("YOU: ").strip()
                if not text:
                    continue
                if text.lower() in ("quit", "exit"):
                    break
                if text.upper().startswith("CMD:"):
                    result = send_command(text[4:].strip())
                    if result:
                        print(json.dumps(result, indent=2))
                else:
                    response, _ = send_turn(text)
                    print(f"HAL: {response or '[NO RESPONSE]'}\n")
            except KeyboardInterrupt:
                print("\nExiting.")
                break

    else:
        print(f"Unknown command: {verb}\n")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
