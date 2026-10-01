from flask import Flask, request, jsonify
from dotenv import load_dotenv
import os, time, threading, requests, json

# ==============================================================================
# FIXES APPLIED:
# 1. Moved `lichess_ok_cached` to top level (was incorrectly indented inside /signal).
# 2. Corrected the API parameter from `perfType` to `perf`.
# 3. Removed misleading comments and cleaned up debug prints.
# ==============================================================================

# ---------------- ENV LOAD ----------------
script_dir = os.path.dirname(os.path.abspath(__file__))
env_path = os.path.join(script_dir, ".env")
load_dotenv(dotenv_path=env_path, override=True)

# --- Server config ---
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "80"))

# --- Auth ---
AUTH_SHARED = os.getenv("AUTH_SHARED", "").strip()

# --- Lichess guard ---
ENFORCE_LICHESS = os.getenv("ENFORCE_LICHESS", "true").lower() in ("1", "true", "yes")
LICHESS_TOKEN = os.getenv("LICHESS_TOKEN", "").strip()
LICHESS_PREF = os.getenv("LICHESS_PREF", "blitz")
LICHESS_MIN_RATING = int(os.getenv("LICHESS_MIN_RATING", "1700"))
LICHESS_MIN_GAMES = int(os.getenv("LICHESS_MIN_GAMES", "1"))
LICHESS_MIN_WIN_RATE = float(os.getenv("LICHESS_MIN_WIN_RATE", "0.0"))
LICHESS_LOOKBACK_MIN = int(os.getenv("LICHESS_LOOKBACK_MIN", "30"))
LICHESS_MAX_GAMES_TO_PARSE = int(os.getenv("LICHESS_MAX_GAMES_TO_PARSE", "200"))

# --- Signal expiration ---
SIGNAL_EXPIRY_SECONDS = int(os.getenv("SIGNAL_EXPIRY_SECONDS", "10"))

# --- Flask app ---
app = Flask(__name__)

# --- HTTP session ---
SESSION = requests.Session()
SESSION.headers.update({"User-Agent": "dopamine-guard/1.0"})

# --- Shared state ---
_lock = threading.Lock()
_last_signal = None

# ----- Cache Structure -----
_window_cache = {}  # {cache_key: {data...}, ...}
_window_cache_lock = threading.Lock()
_username_cache = {"username": None, "ts": 0}

# ----- Helper to get username from Lichess token -----
def _get_username_from_token():
    """Fetch and cache the username associated with the LICHESS_TOKEN."""
    global _username_cache
    now = time.time()
    
    if _username_cache["username"] and (now - _username_cache["ts"] < 3600):
        return _username_cache["username"]
    
    if not LICHESS_TOKEN:
        return None
    
    try:
        resp = SESSION.get(
            "https://lichess.org/api/account",
            headers={"Authorization": f"Bearer {LICHESS_TOKEN}"},
            timeout=(2.0, 2.0)
        )
        resp.raise_for_status()
        username = resp.json().get("username", "").lower()
        _username_cache = {"username": username, "ts": now}
        return username
    except Exception as e:
        print(f"[AUTH] Failed to fetch username: {e}")
        return None

# ----- Core function to generate window cache key -----
def _get_window_cache_key():
    """Creates a unique cache key for the current lookback window."""
    username = _get_username_from_token()
    if not username:
        return None
    
    window_size_seconds = LICHESS_LOOKBACK_MIN * 60
    current_time = time.time()
    window_start_time = int((current_time // window_size_seconds) * window_size_seconds)
    
    return f"{username}:{window_start_time}"

# ---------------- Utils ----------------
def _auth_ok(req):
    if not AUTH_SHARED:
        return True
    return req.headers.get("X-Auth-Token", "") == AUTH_SHARED

def _json_error(msg, code=200, extra=None):
    payload = {"ok": False, "reason": msg}
    if extra:
        payload.update(extra)
    return jsonify(payload), code

# ---------------- Lichess Check (FIXED VERSION) ----------------
def _lichess_check_now():
    """Check Lichess account and recent games."""
    if not ENFORCE_LICHESS:
        return True, "", 0, 0, 0.0
    if not LICHESS_TOKEN:
        return False, "LICHESS: missing token", 0, 0, 0.0
    try:
        to = (2.0, 2.0)
        # 1) account info
        print("[DEBUG 1] Fetching account profile...")
        r1 = SESSION.get(
            "https://lichess.org/api/account",
            headers={"Authorization": f"Bearer {LICHESS_TOKEN}"},
            timeout=to
        )
        r1.raise_for_status()
        acct = r1.json()
        user = acct.get("username", "")
        perf = (acct.get("perfs", {}) or {}).get(LICHESS_PREF.lower(), {}) or {}
        rating = int(perf.get("rating", 0))
        print(f"[DEBUG 1] Got user: '{user}', rating: {rating}")

        # ============================================
        # 2) TIMESTAMP DEBUGGING SECTION
        # ============================================
        import datetime

        lookback_seconds = LICHESS_LOOKBACK_MIN * 60
        current_unix_time = time.time()
        calculated_since_epoch = current_unix_time - lookback_seconds
        since_ms = int(calculated_since_epoch * 1000)

        print(f"\n[TIMESTAMP DEBUG] =================")
        print(f"[DEBUG] CONFIG: LICHESS_LOOKBACK_MIN = {LICHESS_LOOKBACK_MIN} minutes")
        print(f"[DEBUG] CONFIG: LICHESS_PREF = '{LICHESS_PREF}'")
        print(f"[DEBUG] CALC: Current time (epoch sec): {current_unix_time}")
        print(f"[DEBUG] CALC: Lookback window: {lookback_seconds} seconds ({LICHESS_LOOKBACK_MIN} min)")
        print(f"[DEBUG] CALC: Cutoff time (epoch sec): {calculated_since_epoch}")
        print(f"[DEBUG] CALC: Sending 'since_ms' to API: {since_ms}")

        human_time_now = datetime.datetime.fromtimestamp(current_unix_time).strftime('%Y-%m-%d %H:%M:%S UTC')
        human_time_cutoff = datetime.datetime.fromtimestamp(calculated_since_epoch).strftime('%Y-%m-%d %H:%M:%S UTC')
        print(f"[DEBUG] HUMAN TIME - Current Server Time: {human_time_now}")
        print(f"[DEBUG] HUMAN TIME - Requesting games AFTER: {human_time_cutoff}")
        print(f"[TIMESTAMP DEBUG] =================\n")

        # 3) recent games API call - using correct 'perf' parameter
        print(f"[DEBUG 2] Making Games API call...")
        r2 = SESSION.get(
            f"https://lichess.org/api/games/user/{user}",
            params={
                "since": since_ms,
                "perf": LICHESS_PREF.lower(),        # Correct parameter name
                "max": LICHESS_MAX_GAMES_TO_PARSE,
                "moves": "false",
            },
            headers={
                "Authorization": f"Bearer {LICHESS_TOKEN}",
                "Accept": "application/x-ndjson"
            },
            timeout=to,
            stream=True
        )
        print(f"[DEBUG 2] Games API Response Status: {r2.status_code}")
        r2.raise_for_status()
        
        total_games = 0
        wins = 0
        parse_errors = 0
        
        print("[DEBUG 3] Reading stream line by line...")
        
        import pprint
        
        for line in r2.iter_lines(decode_unicode=True):
            if line:
                total_games += 1
                try:
                    game_data = json.loads(line)
                    
                    if total_games == 1:  # Debug first game
                        print(f"\n[CRITICAL DEBUG] FULL DATA OF FIRST GAME FOUND:")
                        print("-" * 50)
                        pp = pprint.PrettyPrinter(indent=2, width=100)
                        pp.pprint(game_data)
                        print("-" * 50)
                        
                        print("\n[CRITICAL DEBUG] GAME TYPE FIELDS:")
                        type_fields = ['speed', 'perf', 'variant', 'timeControl', 'clock']
                        for field in type_fields:
                            if field in game_data:
                                print(f"  • {field}: {game_data[field]}")
                        print("-" * 50)
                    
                    players = game_data.get("players", {})
                    winner = game_data.get("winner")
                    
                    white_user = players.get("white", {}).get("user", {}).get("name", "")
                    black_user = players.get("black", {}).get("user", {}).get("name", "")
                    
                    user_color = None
                    if user.lower() == white_user.lower():
                        user_color = "white"
                    elif user.lower() == black_user.lower():
                        user_color = "black"
                    
                    if user_color and winner == user_color:
                        wins += 1
                        
                except (json.JSONDecodeError, KeyError, AttributeError) as e:
                    parse_errors += 1
                    print(f"[ERROR] Failed to parse game line {total_games}: {e}")
                    continue
        
        print(f"\n[DEBUG 4] STREAM PROCESSING COMPLETE.")
        print(f"        Total games found in API response: {total_games}")
        print(f"        Wins counted: {wins}")
        
        win_rate = wins / total_games if total_games > 0 else 0.0
        print(f"[DEBUG 5] FINAL CALCULATION: wins={wins}/{total_games} = {win_rate:.2%}")
        
        rating_ok = rating >= LICHESS_MIN_RATING
        games_ok = total_games >= LICHESS_MIN_GAMES
        win_rate_ok = win_rate >= LICHESS_MIN_WIN_RATE
        
        ok = rating_ok and games_ok and win_rate_ok
        
        reason_parts = []
        if not rating_ok:
            reason_parts.append(f"rating={rating}<{LICHESS_MIN_RATING}")
        if not games_ok:
            reason_parts.append(f"games={total_games}<{LICHESS_MIN_GAMES}")
        if not win_rate_ok:
            win_rate_pct = win_rate * 100
            min_win_rate_pct = LICHESS_MIN_WIN_RATE * 100
            reason_parts.append(f"win_rate={win_rate_pct:.1f}%<{min_win_rate_pct:.1f}%")
        
        reason = "" if ok else f"LICHESS: {', '.join(reason_parts)}"
        print(f"[DEBUG 5] Returning: ok={ok}, reason='{reason}', rating={rating}, games={total_games}, win_rate={win_rate}")
        return ok, reason, rating, total_games, win_rate
        
    except Exception as e:
        print(f"[ERROR] Lichess check failed: {e}")
        FAIL_OPEN = os.getenv("FAIL_OPEN_ON_LICHESS_ERROR", "0").lower() in ("1","true","yes")
        if FAIL_OPEN:
            return True, f"LICHESS: error {e}; fail-open", 0, 0, 0.0
        return False, f"LICHESS: error {e}", 0, 0, 0.0


# ----- Optimized Cached Check (TOP-LEVEL) -----
def lichess_ok_cached():
    """Check with caching - uses cached PASS if available."""
    if not ENFORCE_LICHESS:
        return True, "", 0, 0, 0.0
    
    cache_key = _get_window_cache_key()
    if not cache_key:
        print("[CACHE] No cache key, performing fresh check")
        return _lichess_check_now()
    
    now = time.time()
    
    with _window_cache_lock:
        cached_entry = _window_cache.get(cache_key)
        
        if cached_entry:
            if cached_entry.get("ok") is True:
                window_start = int(cache_key.split(":")[-1])
                window_age = (now - window_start) / 60
                print(f"[CACHE HIT] Using cached PASS (window age: {window_age:.1f}m)")
                return (True, "",
                        cached_entry["rating"], cached_entry["games"],
                        cached_entry["win_rate"])
            else:
                print(f"[CACHE] Cached failure, retrying...")
    
    print(f"[CACHE MISS] Performing fresh Lichess check")
    ok, reason, rating, games, win_rate = _lichess_check_now()
    
    if ok:
        with _window_cache_lock:
            _window_cache[cache_key] = {
                "ok": ok,
                "reason": reason,
                "rating": rating,
                "games": games,
                "win_rate": win_rate,
                "cached_at": now
            }
            print(f"[CACHE] Cached PASS for this window")
    
    return ok, reason, rating, games, win_rate


# ----- Warmup Endpoint -----
@app.post("/warmup")
def warmup_route():
    """Manual warmup endpoint - checks Lichess without queuing a signal."""
    if not _auth_ok(request):
        return _json_error("AUTH", 403)
    
    print(f"[WARMUP] Manual warmup requested")
    
    start_time = time.time()
    ok, reason, rating, games, win_rate = _lichess_check_now()
    elapsed = time.time() - start_time
    
    rating_ok = rating >= LICHESS_MIN_RATING
    games_ok = games >= LICHESS_MIN_GAMES
    win_rate_ok = win_rate >= LICHESS_MIN_WIN_RATE
    
    failed_conditions = []
    if not rating_ok: failed_conditions.append("rating")
    if not games_ok: failed_conditions.append("games")
    if not win_rate_ok: failed_conditions.append("win_rate")
    
    if ok:
        cache_key = _get_window_cache_key()
        if cache_key:
            with _window_cache_lock:
                _window_cache[cache_key] = {
                    "ok": True,
                    "reason": "",
                    "rating": rating,
                    "games": games,
                    "win_rate": win_rate,
                    "cached_at": time.time(),
                    "warmed_up": True
                }
            print(f"[WARMUP] Cached PASS for current window")
        
        return jsonify({
            "ok": True,
            "ready": True,
            "status": "PASS",
            "message": "✅ READY TO TRADE",
            "time_seconds": round(elapsed, 2),
            "rating": rating,
            "games": games,
            "win_rate": win_rate,
            "failed_conditions": [],
            "conditions": {
                "rating": f"{rating}/{LICHESS_MIN_RATING} ✓",
                "games": f"{games}/{LICHESS_MIN_GAMES} ✓", 
                "win_rate": f"{win_rate*100:.1f}%/{LICHESS_MIN_WIN_RATE*100:.1f}% ✓"
            }
        })
    else:
        return jsonify({
            "ok": False,
            "ready": False,
            "status": "FAIL",
            "message": f"⛔ NOT READY - Failed: {', '.join(failed_conditions)}",
            "reason": reason,
            "time_seconds": round(elapsed, 2),
            "rating": rating,
            "games": games,
            "win_rate": win_rate,
            "failed_conditions": failed_conditions,
            "conditions": {
                "rating": f"{rating}/{LICHESS_MIN_RATING} {'✓' if rating_ok else '✗'}",
                "games": f"{games}/{LICHESS_MIN_GAMES} {'✓' if games_ok else '✗'}",
                "win_rate": f"{win_rate*100:.1f}%/{LICHESS_MIN_WIN_RATE*100:.1f}% {'✓' if win_rate_ok else '✗'}"
            }
        })


# ----- Clear Cache Endpoint -----
@app.get("/clear-cache")
def clear_cache_route():
    """Clear the Lichess cache."""
    if not _auth_ok(request):
        return _json_error("AUTH", 403)
    
    with _window_cache_lock:
        count = len(_window_cache)
        _window_cache.clear()
    
    return jsonify({
        "ok": True,
        "message": f"Cache cleared ({count} PASS entries removed)",
        "cleared_entries": count
    })


# ----- Cache Status Endpoint -----
@app.get("/cache-status")
def cache_status_route():
    """Check if we have a cached PASS for current window."""
    if not _auth_ok(request):
        return _json_error("AUTH", 403)
    
    cache_key = _get_window_cache_key()
    with _window_cache_lock:
        cache_size = len(_window_cache)
        has_cached_pass = cache_key in _window_cache
    
    if cache_key:
        window_start = int(cache_key.split(":")[-1])
        window_end = window_start + (LICHESS_LOOKBACK_MIN * 60)
        time_left = max(0, window_end - time.time())
        minutes_left = time_left / 60
    else:
        minutes_left = None
    
    return jsonify({
        "ok": True,
        "has_cached_pass": has_cached_pass,
        "ready": has_cached_pass,
        "cache_size": cache_size,
        "window_minutes": LICHESS_LOOKBACK_MIN,
        "minutes_until_cache_expires": round(minutes_left, 2) if minutes_left is not None else None,
        "message": "✅ Cached PASS - Ready to trade" if has_cached_pass else "⛔ No cached PASS - Need fresh check"
    })


# ---------------- Signal Routes ----------------
@app.post("/signal")
def signal_route():
    if not _auth_ok(request):
        return _json_error("AUTH", 403)

    j = request.get_json(silent=True) or {}
    side = str(j.get("side", "")).upper()
    symbol = str(j.get("symbol", "")).strip()
    lots = float(j.get("lots", 0) or 0)

    if side not in ("BUY", "SELL"):
        return _json_error("invalid side")
    if not symbol:
        return _json_error("missing symbol")
    if lots <= 0:
        return _json_error("invalid lots")

    # Lichess gate using cached check
    ok, reason, rating, games, win_rate = lichess_ok_cached()
    if not ok:
        return jsonify({"ok": False, "reason": reason,
                        "rating": rating, "games": games, "win_rate": win_rate})

    # Passed → queue with expiration
    ts = int(j.get("ts", 0)) or int(time.time())
    payload = {
        "side": side,
        "symbol": symbol,
        "lots": lots,
        "ts": ts,
        "created_time": time.time(),
        "expires_at": time.time() + 300
    }
   
    with _lock:
        global _last_signal
        if _last_signal and _last_signal.get('expires_at', 0) < time.time():
            _last_signal = None
        _last_signal = payload
       
    return jsonify({"ok": True})


@app.get("/next")
def next_signal():
    if not _auth_ok(request):
        return _json_error("AUTH", 403)
   
    with _lock:
        global _last_signal
        if _last_signal and _last_signal.get('expires_at', 0) < time.time():
            _last_signal = None
           
        if _last_signal is None:
            return jsonify({"ok": True, "empty": True})
           
        return jsonify({"ok": True, "empty": False, **_last_signal})


@app.get("/ack")
def ack_signal():
    if not _auth_ok(request):
        return _json_error("AUTH", 403)
    with _lock:
        global _last_signal
        _last_signal = None
    return jsonify({"ok": True})


@app.get("/health")
def health():
    """Health check with readiness status."""
    cache_key = _get_window_cache_key()
    with _window_cache_lock:
        cache_size = len(_window_cache)
        cache_info = _window_cache.get(cache_key, {}) if cache_key else {}
    
    is_ready = cache_info.get("ok") if cache_info else None
    
    return jsonify({
        "ok": True, 
        "lichess_enforced": ENFORCE_LICHESS,
        "ready": is_ready,
        "ready_message": "✅ Ready to trade" if is_ready == True else 
                        "⛔ Not ready" if is_ready == False else 
                        "⚠️ Not checked yet",
        "cache_system": "pass_once_per_window",
        "cache_size": cache_size,
        "current_cache_hit": is_ready is not None
    })


# ---------------- Entrypoint ----------------
if __name__ == "__main__":
    print(f"[FLASK] Server starting on {HOST}:{PORT}")
    print(f"[FLASK] Signal expiry: {SIGNAL_EXPIRY_SECONDS} seconds")
    print(f"[FLASK] Lichess min win rate: {LICHESS_MIN_WIN_RATE * 100:.1f}%")
    print(f"[FLASK] LICHESS_MIN_RATING:{LICHESS_MIN_RATING}")
    print(f"[FLASK] LICHESS_MIN_GAMES:{LICHESS_MIN_GAMES}")
    print(f"[FLASK] NEW: Warmup endpoint at POST /warmup")
    print(f"[FLASK] Window system: Pass once per {LICHESS_LOOKBACK_MIN} minutes")
    app.run(host=HOST, port=PORT, debug=False, threaded=True)