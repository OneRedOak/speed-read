#!/usr/bin/env python3
"""Persistent Kokoro TTS daemon for sr (P-9).

Adapted from Speak11's tts_server.py (public domain). Keeps the Kokoro
model loaded in memory and serves TTS requests over a Unix domain socket.

Security model (P-9):
  - Unix socket only, mode 0600, under ~/Library/Application Support/sr/kokoro/.
    Never TCP.
  - Per-launch auth token: the Swift supervisor passes SR_DAEMON_TOKEN in the
    environment; every request must carry a matching "token" field or the
    connection is refused.

Protocol (one JSON object per line, UTF-8):
  request:  {"token": "<hex>", "text": "...", "voice": "bf_lily",
             "speed": "1.0", "lang_code": "b"}
  response: {"status": "ok", "audio_file": "/abs/path.wav"}
        or  {"status": "error", "message": "..."}
  The CLIENT owns the returned WAV file and its parent temp directory and
  must delete both after reading. Orphaned temp dirs are swept at daemon
  startup.

Modes:
  Default:   auto-shuts down after idle timeout (SR_IDLE_TIMEOUT, default 300s).
  --managed: no idle timeout; shuts down when the parent process exits
             (or on SIGTERM).

Logging is content-free (P-5): text lengths only, never text.
"""

import fcntl
import json
import os
import signal
import socket
import sys
import tempfile
import threading
import time

# ── Paths ────────────────────────────────────────────────────────────

DATA_DIR = os.path.expanduser("~/Library/Application Support/sr/kokoro")
SOCKET_PATH = os.path.join(DATA_DIR, "daemon.sock")
PID_FILE = os.path.join(DATA_DIR, "daemon.pid")
LOCK_FILE = os.path.join(DATA_DIR, "daemon.lock")
TMP_ROOT = os.path.join(DATA_DIR, "tmp")
LOG_DIR = os.path.expanduser("~/Library/Logs/sr")
LOG_FILE = os.path.join(LOG_DIR, "kokoro.log")

MODEL_ID = "mlx-community/Kokoro-82M-bf16"

# Idle timeout in seconds (non-managed mode).
IDLE_TIMEOUT = int(os.environ.get("SR_IDLE_TIMEOUT", "300"))

# Per-launch auth token (required).
AUTH_TOKEN = os.environ.get("SR_DAEMON_TOKEN", "")

# ── Logging (content-free, P-5) ──────────────────────────────────────


def log(msg):
    """Append a timestamped line to the log. Never log request text."""
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(
                f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] sr_tts_server: {msg}\n"
            )
    except OSError:
        pass


# ── Globals ──────────────────────────────────────────────────────────

model = None
last_request_time = time.time()
server_socket = None
shutdown_event = threading.Event()
managed_mode = False
generation_lock = threading.Lock()

# ── Model ────────────────────────────────────────────────────────────


def load_tts_model():
    global model
    from mlx_audio.tts.utils import load_model

    log(f"loading model {MODEL_ID}")
    model = load_model(MODEL_ID)
    log("model loaded")


def warmup_pipeline():
    """Pre-cache the language pipeline so the first real request is fast."""
    try:
        log("warming up pipeline")
        for _ in model.generate(text=".", voice="bf_lily", speed=1.0, lang_code="b"):
            pass
        log("pipeline warm")
    except Exception as e:
        log(f"warmup failed (non-fatal): {type(e).__name__}")


class CancelledError(Exception):
    """Raised when a generation is cancelled (client disconnected)."""


def generate_audio(text, voice, speed, lang_code, cancel_check=None):
    """Generate a WAV file from text. Returns the file path.

    The caller's client owns the file and its parent dir (deletes after
    reading).
    """
    import numpy as np
    from mlx_audio.audio_io import write as audio_write

    os.makedirs(TMP_ROOT, exist_ok=True)
    tmp_dir = tempfile.mkdtemp(prefix="gen_", dir=TMP_ROOT)
    out_path = os.path.join(tmp_dir, "out.wav")

    try:
        results = model.generate(
            text=text,
            voice=voice,
            speed=float(speed),
            lang_code=lang_code,
        )

        segments = []
        sample_rate = None
        for result in results:
            if cancel_check and cancel_check():
                raise CancelledError("client disconnected")
            segments.append(np.array(result.audio))
            sample_rate = result.sample_rate

        if not segments or sample_rate is None:
            raise RuntimeError("model produced no audio")

        audio = np.concatenate(segments) if len(segments) > 1 else segments[0]
        audio_write(out_path, audio, sample_rate, format="wav")

        if not os.path.isfile(out_path) or os.path.getsize(out_path) == 0:
            raise RuntimeError("audio file empty after write")

        del segments, audio
        return out_path

    except Exception:
        import shutil

        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise


# ── Client handler ───────────────────────────────────────────────────


def _client_gone(conn):
    """Non-blocking check: has the client closed the connection?"""
    import select
    try:
        readable, _, _ = select.select([conn], [], [], 0)
        if readable:
            data = conn.recv(1, socket.MSG_PEEK)
            return len(data) == 0
        return False
    except OSError:
        return True


def handle_client(conn):
    """Read one JSON request, check token, generate audio, respond."""
    global last_request_time
    last_request_time = time.time()

    def send(obj):
        try:
            conn.sendall((json.dumps(obj) + "\n").encode("utf-8"))
        except OSError:
            pass

    try:
        data = b""
        conn.settimeout(10)
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break

        if not data.strip():
            return

        request = json.loads(data.decode("utf-8").strip())

        # ── Auth (P-9) ──
        if not AUTH_TOKEN or request.get("token", "") != AUTH_TOKEN:
            log("request rejected: bad token")
            send({"status": "error", "message": "unauthorized"})
            return

        text = request.get("text", "")
        voice = request.get("voice", "bf_lily")
        speed = request.get("speed", "1.0")
        lang_code = request.get("lang_code", "b")

        log(f"request: text_len={len(text)} voice={voice} speed={speed} lang={lang_code}")

        with generation_lock:
            audio_file = generate_audio(
                text, voice, speed, lang_code,
                cancel_check=lambda: _client_gone(conn),
            )

        send({"status": "ok", "audio_file": audio_file})
        log(f"response: ok bytes={os.path.getsize(audio_file)}")

    except CancelledError:
        log("generation cancelled (client disconnected)")
    except Exception as e:
        # Content-free: exception type + message may describe internals but
        # never echoes request text (model errors reference voices/shapes).
        log(f"error: {type(e).__name__}: {e}")
        send({"status": "error", "message": f"{type(e).__name__}: {e}"})
    finally:
        try:
            conn.close()
        except OSError:
            pass
        # Release MLX metal buffers after the response (not between
        # sentences) so back-to-back requests don't pay gc overhead.
        import gc

        import mlx.core as mx

        gc.collect()
        mx.metal.clear_cache()


# ── Watchdogs ────────────────────────────────────────────────────────


def idle_watchdog():
    while not shutdown_event.is_set():
        remaining = IDLE_TIMEOUT - (time.time() - last_request_time)
        if remaining <= 0:
            log(f"idle for {IDLE_TIMEOUT}s, shutting down")
            do_shutdown()
            return
        shutdown_event.wait(min(remaining + 0.5, 10))


def parent_watchdog():
    """Managed mode: exit if the parent (sr.app) dies."""
    parent_pid = os.getppid()
    if parent_pid <= 1:
        log("already orphaned at startup, shutting down")
        do_shutdown()
        return
    log(f"parent watchdog started (parent pid={parent_pid})")
    while not shutdown_event.is_set():
        if os.getppid() != parent_pid:
            log(f"parent died (was {parent_pid}), shutting down")
            do_shutdown()
            return
        shutdown_event.wait(2)


# ── Shutdown ─────────────────────────────────────────────────────────


def do_shutdown():
    shutdown_event.set()
    if server_socket is not None:
        try:
            server_socket.close()
        except OSError:
            pass
    for path in (SOCKET_PATH, PID_FILE):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    log("shutdown complete")
    os._exit(0)


def handle_signal(signum, _frame):
    log(f"received signal {signum}")
    do_shutdown()


# ── Main ─────────────────────────────────────────────────────────────


def main():
    global server_socket, managed_mode

    managed_mode = "--managed" in sys.argv[1:]

    if not AUTH_TOKEN:
        log("refusing to start: SR_DAEMON_TOKEN not set")
        sys.exit(2)

    os.makedirs(DATA_DIR, exist_ok=True)

    # Exclusive lock — at most one daemon. Held for process lifetime,
    # released automatically on any exit.
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)  # another daemon holds the lock

    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    # Sweep temp dirs orphaned by interrupted generations.
    import glob
    import shutil

    for d in glob.glob(os.path.join(TMP_ROOT, "gen_*")):
        shutil.rmtree(d, ignore_errors=True)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Load model (slow — the supervisor polls for the socket to appear).
    load_tts_model()
    warmup_pipeline()

    if managed_mode:
        watchdog = threading.Thread(target=parent_watchdog, daemon=True)
    else:
        watchdog = threading.Thread(target=idle_watchdog, daemon=True)
    watchdog.start()

    # Creating the socket signals readiness. 0600 before listen (P-9).
    server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    umask_prev = os.umask(0o177)
    try:
        server_socket.bind(SOCKET_PATH)
    finally:
        os.umask(umask_prev)
    os.chmod(SOCKET_PATH, 0o600)
    server_socket.listen(2)
    server_socket.settimeout(5)

    mode_str = "managed" if managed_mode else f"idle timeout {IDLE_TIMEOUT}s"
    log(f"listening ({mode_str})")

    # Each client in a thread so a new request can cancel a long-running
    # generation (old client disconnects, cancel_check fires).
    while not shutdown_event.is_set():
        try:
            conn, _ = server_socket.accept()
            t = threading.Thread(target=handle_client, args=(conn,), daemon=True)
            t.start()
        except socket.timeout:
            continue
        except OSError:
            if not shutdown_event.is_set():
                log("socket error in accept loop")
            break

    do_shutdown()


if __name__ == "__main__":
    main()
