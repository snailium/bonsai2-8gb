#!/usr/bin/env bash
# Claim 3: with this build, running WITHOUT MTP makes the model emit only '/'.
#
# usage: 03-no-mtp-collapse.sh <bin-dir> [lean.gguf] [original.gguf]
#
# This is the strongest claim in the write-up and the most surprising, so the
# script runs the controls that rule out the obvious explanations:
#   - two different model files   (rules out "it's the MTP-grafted file")
#   - thinking on and off         (rules out "it's the reasoning path")
#   - two context sizes           (rules out "it's a context-size effect")
#   - with-MTP control            (proves the same setup works when MTP is on)
set -uo pipefail

BIN="${1:?usage: 03-no-mtp-collapse.sh <bin-dir> [lean.gguf] [original.gguf]}"
LEAN="${2:-$HOME/models/bonsai2/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf}"
ORIG="${3:-$HOME/models/bonsai2/PTQ1_0.gguf}"
KV="$(dirname "$LEAN")/kv-mean-center.gguf"
PORT="${PORT:-18791}"
export LD_LIBRARY_PATH="$BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

probe() {   # probe <nothink?>
  python3 - "$1" <<'PY'
import json, sys, urllib.request
BASE = "http://127.0.0.1:18791/v1/chat/completions"
nothink = sys.argv[1] == "nothink"
p = {"model": "probe",
     "messages": [{"role": "user", "content": "What is 2+2?"}],
     "max_tokens": 200, "stream": True,
     "stream_options": {"include_usage": True}}
if nothink:
    p["chat_template_kwargs"] = {"enable_thinking": False}
req = urllib.request.Request(BASE, data=json.dumps(p).encode(),
                             headers={"Content-Type": "application/json"})
th, ct = [], []
with urllib.request.urlopen(req, timeout=300) as r:
    for raw in r:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        d = line[5:].strip()
        if d == "[DONE]":
            break
        try:
            o = json.loads(d)
        except json.JSONDecodeError:
            continue
        for ch in o.get("choices", []):
            dl = ch.get("delta") or {}
            if dl.get("reasoning_content"):
                th.append(dl["reasoning_content"])
            if dl.get("content"):
                ct.append(dl["content"])
T, C = "".join(th), "".join(ct)
total = T + C
slash_ratio = total.count("/") / len(total) if total else 0.0
verdict = "COLLAPSE" if slash_ratio > 0.8 else ("ok" if C.strip() else "EMPTY")
print(f"      thinking={'off' if nothink else 'on':3s}  reasoning={len(T):5d}  "
      f"content={len(C):5d}  slash_ratio={slash_ratio:.2f}  -> {verdict}")
if C:
    print(f"      content[:60] = {C[:60]!r}")
PY
}

cell() {   # cell <label> <model> <ctx> [extra args...]
  local label="$1" model="$2" ctx="$3"; shift 3
  echo "  --- $label ---"
  local log; log="$(mktemp)"
  timeout 200 "$BIN/llama-server" -m "$model" -ngl 99 -fa on -c "$ctx" -np 1 \
    -ctk q4_0 -ctv q4_0 --kv-mean-center "$KV" --jinja \
    --host 127.0.0.1 --port "$PORT" "$@" >"$log" 2>&1 &
  local pid=$! ok=0
  for _ in $(seq 1 30); do
    sleep 5
    grep -q "listening on" "$log" 2>/dev/null && { ok=1; break; }
    kill -0 "$pid" 2>/dev/null || break
  done
  if [ "$ok" = 1 ]; then
    probe think
    probe nothink
  else
    echo "      (server failed to load)"
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 4
  rm -f "$log"
}

echo "=== control: WITH MTP (expect: works) ==="
cell "32K + MTP, lean file" "$LEAN" 32768 --spec-type draft-mtp --spec-draft-n-max 1

echo
echo "=== without MTP -- the collapse ==="
cell "32K no MTP, lean file"      "$LEAN" 32768
cell "32K no MTP, lean file (2)"  "$LEAN" 32768
cell "64K no MTP, lean file"      "$LEAN" 65536
if [ -f "$ORIG" ]; then
  cell "32K no MTP, ORIGINAL file" "$ORIG" 32768
  cell "64K no MTP, ORIGINAL file" "$ORIG" 65536
else
  echo "  (skipped original-file controls: $ORIG not present)"
fi

cat <<'NOTE'

Expected: the WITH-MTP control returns a coherent answer ("Four"). Every no-MTP
cell returns slash_ratio ~1.00, in both thinking modes, for both model files.

This rules out:
  - the MTP-grafted lean file   (the original PTQ1_0.gguf collapses too)
  - the reasoning path          (thinking-off collapses in `content`, not reasoning)
  - context size                (32K and 64K both collapse)

What it does NOT establish: the mechanism. Something in this build appears to
depend on the MTP draft context being initialised. We report the observation, not
a cause.
NOTE
