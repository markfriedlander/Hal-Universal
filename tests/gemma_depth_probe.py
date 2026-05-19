#!/usr/bin/env python3
"""
Gemma memory-depth tuning probe.

For a given memory depth, NUCLEAR_RESET first to wipe history,
SET_MEMORY_DEPTH:N, then drive a varied multi-turn conversation
until the model fails (graceful refusal, crash, or empty response).

Per-turn log: turn number, RSS if reported, response length, any
error signal. Final summary: turns_completed, failure_mode, sample
of failing turn.

Usage:
  python3 tests/gemma_depth_probe.py <depth>   # 2, 3, 4, 5
"""
import json
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CONFIG = json.loads((REPO / "tests" / ".hal_api_config.json").read_text())
BASE = f"http://{CONFIG['host']}:{CONFIG['port']}"
TOKEN = CONFIG['token']
DEVICE = "D24FB384-9C55-5D33-9B0D-DAEBFA6528D6"
BUNDLE = "com.MarkFriedlander.Hal-Universal"

# A varied conversational arc designed to exercise different aspects
# and grow context steadily. Memory-probe questions reference earlier
# turns explicitly to force attention over the full window.
PROMPTS = [
    "Hi. I'm Mark. I'm an iOS developer working on a transparency-first AI assistant called Hal. Could you respond briefly?",
    "What's seventeen times twenty-four? Show the steps.",
    "Name three rivers in South America.",
    "I love hiking in the Sierras. Got a favorite trail you'd recommend?",
    "Summarize the plot of Hamlet in two sentences.",
    "Translate 'good morning, how are you?' into French and into German.",
    "What's the capital of Mongolia?",
    "Earlier I told you my name. What was it?",
    "Write a four-line haiku about a sleeping cat.",
    "If a train leaves Chicago at 3 PM going 60 mph toward Detroit (282 miles), when does it arrive?",
    "Explain in three sentences what a KV cache is in transformer inference.",
    "What do I do for a living? I mentioned it in my first message.",
    "Pretend you're a museum docent describing a Vermeer painting. One paragraph.",
    "What's the difference between weather and climate?",
    "Recommend a book for someone who liked Borges' Ficciones.",
    "I mentioned a hobby earlier. What was it?",
    "Compose a brief inner monologue for a character who has just realized she left the stove on.",
    "Define 'epistemology' in one sentence.",
    "What's the AI assistant I'm building called? I told you the name.",
    "Give me three uses for a binder clip beyond holding paper.",
    "Translate this Spanish sentence: 'El gato duerme en la silla del jardín.'",
    "Roll-up question: from everything I've told you so far, draw a small portrait of who I am — three sentences.",
    "What was the math problem I asked about? Just remind me of the answer.",
    "Write a short product description for a mug that keeps coffee hot for six hours.",
    "Briefly compare relativism and absolutism in ethics.",
    "What was the haiku topic I asked for earlier? Recite the haiku you wrote.",
    "Give me three good icebreaker questions for a dinner party.",
    "Suggest a one-day itinerary for a tourist in Reykjavík.",
    "What did I say I love doing in the Sierras?",
    "Explain in plain English what an LLM context window is.",
    "Write three plausible reasons a software project might miss its deadline.",
    "Now tell me, in three sentences, the most interesting thing about our conversation so far.",
    "What's the German word for 'curiosity'?",
    "If you had to summarize my interests in one line, what would you say?",
    "Tell me a joke about computer programmers.",
    "Earlier I asked about a Vermeer painting. What style did you describe?",
    "What is one thing you don't know about me that you'd want to ask?",
    "Final question: based on our whole conversation, write a one-paragraph reflection in your own voice.",
]


def _post(path: str, payload: dict, timeout: float) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        BASE + path, data=body, method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def _get(path: str, timeout: float) -> dict:
    req = urllib.request.Request(
        BASE + path, method="GET",
        headers={"Authorization": f"Bearer {TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def http_call(cmd: str, timeout: float = 300.0) -> dict:
    return _post("/command", {"command": cmd}, timeout)


def http_chat(message: str, timeout: float = 300.0) -> dict:
    return _post("/chat", {"message": message}, timeout)


def http_state(timeout: float = 30.0) -> dict:
    return _get("/state", timeout)


def _list_pid() -> int | None:
    """Find Hal Universal PID on device via devicectl."""
    r = subprocess.run(
        ["xcrun", "devicectl", "device", "info", "processes",
         "--device", DEVICE],
        capture_output=True, text=True, timeout=30,
    )
    for line in r.stdout.splitlines():
        if "Hal Universal" in line or BUNDLE in line:
            parts = line.split()
            if parts and parts[0].isdigit():
                return int(parts[0])
    return None


def relaunch_app(wait: float = 25.0):
    """Hard terminate Hal then cold-launch and wait for Gemma to load.

    devicectl's `process launch` alone does not unload MLX weights — iOS
    keeps the prior process state if it's still resident. To actually
    free memory we must signal-terminate first, give iOS a moment to
    reclaim, then launch fresh and wait for Gemma to MMAP back in
    (~10-15s on iPhone 16 Plus).
    """
    pid = _list_pid()
    if pid:
        subprocess.run(
            ["xcrun", "devicectl", "device", "process", "terminate",
             "--device", DEVICE, "--pid", str(pid)],
            capture_output=True, timeout=30,
        )
        time.sleep(3)
    subprocess.run(
        ["xcrun", "devicectl", "device", "process", "launch",
         "--device", DEVICE, BUNDLE],
        capture_output=True, timeout=30,
    )
    time.sleep(wait)


def safe_call(cmd: str, retries: int = 3, timeout: float = 300.0) -> dict | None:
    for attempt in range(retries):
        try:
            return http_call(cmd, timeout=timeout)
        except Exception as e:
            print(f"  CALL ERR (attempt {attempt+1}): {e}")
            relaunch_app()
    return None


def main():
    if len(sys.argv) != 2:
        print("usage: gemma_depth_probe.py <depth>")
        sys.exit(2)
    depth = int(sys.argv[1])
    print(f"=== Gemma depth probe — depth={depth} ===")

    relaunch_app()
    print("App relaunched.")

    print("Resetting...")
    r = safe_call("NUCLEAR_RESET")
    print(f"  RESET: {r}")
    relaunch_app(wait=10)

    print(f"Setting depth={depth}...")
    r = safe_call(f"SET_MEMORY_DEPTH:{depth}")
    print(f"  SET: {r}")

    # Confirm Gemma is loaded
    try:
        st = http_state()
        print(f"  state: model={st.get('modelID')} depth={st.get('memoryDepth')} max={st.get('maxMemoryDepth')}")
    except Exception as e:
        print(f"  state read failed: {e}")

    def reapply_depth():
        """After any relaunch the app re-runs init → applyEffectiveSettings,
        which overwrites memoryDepth back to the active model's default. So we
        must re-SET our target depth after each relaunch or chats silently
        run at the wrong depth."""
        try:
            r = http_call(f"SET_MEMORY_DEPTH:{depth}", timeout=15)
            print(f"  re-SET depth={depth}: {r}", flush=True)
        except Exception as e:
            print(f"  re-SET err: {e}", flush=True)

    def safe_chat(message: str, retries: int = 2, timeout: float = 300.0):
        for attempt in range(retries + 1):
            try:
                return http_chat(message, timeout=timeout)
            except Exception as e:
                print(f"  CHAT ERR (attempt {attempt+1}): {e}", flush=True)
                relaunch_app()
                reapply_depth()
        return None

    failure_mode = None
    failing_turn = None
    completed = 0
    for i, prompt in enumerate(PROMPTS, start=1):
        # Verify depth before each turn so contamination from a silent
        # relaunch is detected, not buried.
        try:
            stp = http_state(timeout=10)
            actual_depth = stp.get("memoryDepth")
            if actual_depth != depth:
                print(f"  [WARN] state.memoryDepth={actual_depth} != target depth={depth}; re-SETting", flush=True)
                http_call(f"SET_MEMORY_DEPTH:{depth}", timeout=10)
        except Exception:
            pass
        print(f"\n--- TURN {i} [depth={depth}] ---")
        print(f"USER: {prompt}")
        t0 = time.time()
        r = safe_chat(prompt, retries=2, timeout=300)
        dt = time.time() - t0
        if r is None:
            failure_mode = "crash_no_response"
            failing_turn = i
            print(f"  CRASH: no response after retries")
            break
        if "error" in r:
            failure_mode = f"err:{r['error']}"
            failing_turn = i
            print(f"  ERR: {r}")
            break
        reply = (r.get("response") or "").strip()
        print(f"HAL ({dt:.1f}s, {len(reply)} chars): {reply[:300]}")
        if not reply:
            failure_mode = "empty_response"
            failing_turn = i
            print("  WARN: empty response — counting as failure")
            break
        low = reply.lower()
        if any(needle in low for needle in [
            "insufficient memory", "memory pressure", "i had to stop",
            "couldn't generate", "context window", "had to refuse",
            "not enough memory"
        ]):
            print(f"  GRACEFUL REFUSAL detected — stopping")
            failure_mode = "graceful_refusal"
            failing_turn = i
            completed = i  # the refusal turn itself counts
            break
        # Ground-truth check: after each chat, fetch the HALDEBUG-CHAT
        # line and parse out the depth= value the chat path actually used.
        try:
            lr = http_call("GET_LOGS:50", timeout=15)
            actual_chat_depth = None
            for entry in reversed(lr.get("logs", [])):
                if "HALDEBUG-CHAT" in entry and "depth=" in entry:
                    m = re.search(r"depth=(\d+)", entry)
                    if m:
                        actual_chat_depth = int(m.group(1))
                        break
            if actual_chat_depth is not None and actual_chat_depth != depth:
                print(f"  [BUG] chat-time depth={actual_chat_depth} != target {depth} — data tainted at turn {i}", flush=True)
            elif actual_chat_depth is not None:
                print(f"  ground-truth: chat ran at depth={actual_chat_depth} ✓", flush=True)
        except Exception as e:
            print(f"  log-check err: {e}", flush=True)

        completed = i
        # Sanity check the API still alive
        if i % 5 == 0:
            try:
                s = http_state()
                print(f"  state-ping: turnCount={s.get('turnCount')} memoryDepth={s.get('memoryDepth')}")
            except Exception as e:
                print(f"  state-ping failed: {e}")

    print(f"\n=== RESULT depth={depth} ===")
    print(f"  completed_turns: {completed}")
    print(f"  failure_mode: {failure_mode}")
    print(f"  failing_turn: {failing_turn}")


if __name__ == "__main__":
    main()
