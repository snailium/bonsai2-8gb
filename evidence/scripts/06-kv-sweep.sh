#!/bin/bash
# Which KV cache types actually load AND serve on this build/GPU?
# For each type: start server at a FIXED context, check load, measure VRAM + decode.
BIN=/home/gwang/bonsai2/src/build/bin
export LD_LIBRARY_PATH=$BIN
M=/home/gwang/bonsai2/models/mtp-lean.gguf
KV=/home/gwang/bonsai2/models/kv-mean-center.gguf
CTX=32768
PORT=18810

probe() {
  python3 - <<'PY'
import json,urllib.request,time
BASE="http://127.0.0.1:18810/v1/chat/completions"
p={"messages":[{"role":"user","content":"Write a Python fibonacci function. Keep it short."}],
   "max_tokens":200,"stream":False}
req=urllib.request.Request(BASE,data=json.dumps(p).encode(),headers={"Content-Type":"application/json"})
t0=time.time()
try:
    with urllib.request.urlopen(req,timeout=180) as r: d=json.load(r)
    t=d.get("timings") or {}
    c=d["choices"][0]["message"].get("content") or ""
    rc=d["choices"][0]["message"].get("reasoning_content") or ""
    ok = 'def ' in c or 'fib' in c.lower()
    print(f"      decode={t.get('predicted_per_second',0):6.2f} t/s  coherent={'yes' if ok else 'NO'}")
except Exception as e:
    print(f"      request failed: {str(e)[:70]}")
PY
}

for pair in "f16 f16" "q8_0 q8_0" "q4_0 q4_0" "q5_0 q5_0" "q5_1 q5_1" "q4_1 q4_1" "iq4_nl iq4_nl" "q4_0 q8_0" "q8_0 q4_0"; do
  set -- $pair; k=$1; v=$2
  printf "  %-16s " "-ctk $k -ctv $v"
  extra=""
  # kv-mean-center only applies to q4_0 K
  [ "$k" = "q4_0" ] && extra="--kv-mean-center $KV"
  log=/tmp/kv_${k}_${v}.log
  $BIN/llama-server -m $M -ngl 99 -fa on -c $CTX -np 1 \
    -ctk $k -ctv $v $extra --jinja \
    --spec-type draft-mtp --spec-draft-n-max 1 \
    --host 127.0.0.1 --port $PORT > "$log" 2>&1 &
  pid=$!; ok=0
  for i in $(seq 1 24); do sleep 5; grep -q "listening on" "$log" 2>/dev/null && { ok=1; break; }; kill -0 $pid 2>/dev/null || break; done
  if [ $ok = 1 ]; then
    vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)
    echo "LOADED  VRAM=${vram}"
    probe
  else
    echo "FAILED  $(grep -oE 'error[^\"]{0,70}' "$log" | tail -1)"
  fi
  kill $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 4
done
echo "KVSWEEP_DONE"
