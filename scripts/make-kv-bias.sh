#!/usr/bin/env bash
# Generate the q4_0 K-cache mean-centering bias for a model.
#
# The bias is model-specific AND rotation-state-specific. It must be calibrated
# with the same cache settings used at serve time (-fa on -ctk q4_0), otherwise
# the server refuses to load it (a deliberate safety check).
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin"
export LD_LIBRARY_PATH="$BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

MODEL="${1:?usage: make-kv-bias.sh <model.gguf> [calibration.txt]}"
CALIB="${2:-}"

if [[ -z "$CALIB" ]]; then
  CALIB="$(mktemp)"
  python3 - "$CALIB" <<'PY'
import random, sys
paras = [
 "The quick brown fox jumps over the lazy dog and this sentence contains every letter of the alphabet.",
 "Artificial intelligence systems process natural language by tokenizing text into smaller units and learning statistical patterns.",
 "A transformer uses self-attention to weigh the relevance of each token against every other token in the sequence.",
 "Quantization reduces numerical precision of model weights, trading a little accuracy for large memory savings.",
 "Memory bandwidth is often the limiting factor for token generation, since every weight is streamed per token.",
 "Prompt processing is compute bound, so throughput scales with available floating point operations.",
 "The KV cache grows linearly with context length, which is why quantizing it enables longer conversations.",
 "Code review checks input validation, authentication boundaries, error handling, resource cleanup and cryptography.",
]
random.seed(42)
open(sys.argv[1], "w").write(" ".join(random.choice(paras) for _ in range(200)))
PY
  echo "note: generated a synthetic calibration corpus ($CALIB)"
  echo "      pass your own text file as the 2nd argument for better results"
fi

OUT="$(dirname "$MODEL")/kv-mean-center.gguf"
echo "generating bias -> $OUT"
"$BIN/llama-kv-mean-center" -m "$MODEL" -f "$CALIB" -fa on -ctk q4_0 -o "$OUT" 2>/dev/null \
 || "$BIN/llama-kv-mean-center" -m "$MODEL" -f "$CALIB" -fa on -ctk q4_0
echo "done: $OUT"
