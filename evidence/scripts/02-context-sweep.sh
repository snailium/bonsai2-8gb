#!/usr/bin/env bash
# Claim 2: the real context ceiling on an 8 GB card, with and without MTP.
#
# usage: 02-context-sweep.sh <bin-dir> [model.gguf] [kv-bias.gguf]
#
# Loads a server at each -c and reports whether it comes up and how much VRAM it
# holds. Stops each one. Nothing here needs a client.
set -uo pipefail

BIN="${1:?usage: 02-context-sweep.sh <bin-dir> [model.gguf] [kv-bias.gguf]}"
MODEL="${2:-$HOME/models/bonsai2/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf}"
KV="${3:-$(dirname "$MODEL")/kv-mean-center.gguf}"
PORT="${PORT:-18790}"
export LD_LIBRARY_PATH="$BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

try() {   # try <label> <ctx> [extra server args...]
  local label="$1" ctx="$2"; shift 2
  local log; log="$(mktemp)"
  printf '  %-22s -c %-7s ' "$label" "$ctx"
  timeout 150 "$BIN/llama-server" -m "$MODEL" -ngl 99 -fa on -c "$ctx" -np 1 \
    -ctk q4_0 -ctv q4_0 --kv-mean-center "$KV" --jinja \
    --host 127.0.0.1 --port "$PORT" "$@" >"$log" 2>&1 &
  local pid=$! ok=0
  for _ in $(seq 1 28); do
    sleep 5
    grep -q "listening on" "$log" 2>/dev/null && { ok=1; break; }
    kill -0 "$pid" 2>/dev/null || break
  done
  if [ "$ok" = 1 ]; then
    echo "LOADED   $(nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader)"
  else
    echo "FAILED   $(grep -oE 'allocating [0-9.]+ MiB.*out of memory' "$log" | tail -1)"
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 4
  rm -f "$log"
}

echo "=== with MTP (--spec-type draft-mtp --spec-draft-n-max 1) ==="
for c in 32768 40960 49152 65536; do
  try "with MTP" "$c" --spec-type draft-mtp --spec-draft-n-max 1
done

echo
echo "=== without MTP ==="
for c in 32768 65536 73728 81920 90112; do
  try "no MTP" "$c"
done

cat <<'NOTE'

Expected (RTX 5060 8 GB, 7704 MiB usable):
  with MTP : 32768 OK (7284) | 40960 OK (7508) | 49152 FAIL | 65536 FAIL
  no MTP   : 65536 OK (7268) | 73728 OK (7452) | 81920 OK (7636) | 90112 FAIL

So the golden config is 40960 WITH MTP. Going higher requires dropping MTP --
but see script 03: that makes the model unusable.

Failure mode is always the same and is NOT the KV cache:
  ggml_backend_cuda_buffer_type_alloc_buffer: allocating NNN MiB ... cudaMalloc failed
  graph_reserve: failed to allocate compute buffers
NOTE
