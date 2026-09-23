#!/usr/bin/env bash
# Claim 1: kernel-only decode, this build vs the stock PrismML release.
#
# usage: 01-bench-tg128.sh <bin-dir> [model.gguf]
#
# llama-bench cannot test MTP (it rejects --spec-type), so this measures the
# PTQ1_0 kernel alone. That is the point: it isolates the +37% from PR #218.
set -euo pipefail

BIN="${1:?usage: 01-bench-tg128.sh <bin-dir> [model.gguf]}"
MODEL="${2:-$HOME/models/bonsai2/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf}"
export LD_LIBRARY_PATH="$BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=== llama-bench tg128 / pp512, 3 reps, fresh context ==="
"$BIN/llama-bench" -m "$MODEL" \
  -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 \
  -p 512 -n 128 -r 3 -d 0

cat <<'NOTE'

Expected (our card):
  pp512   349.43 ± 2.86
  tg128    54.31 ± 0.15
  build: dcc3be7

Stock PrismML release b10685 on the same card: tg128 39.56  -> +37%

To A/B against the stock binary, run the same command with that binary.
NOTE
