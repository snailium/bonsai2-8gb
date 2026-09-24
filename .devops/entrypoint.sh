#!/bin/bash
# Entrypoint for the bonsai2 CUDA image.
#
#  1. make sure the weights are on the volume (download them once if needed)
#  2. make sure the required KV calibration bias is there
#  3. hand off to llama-server, which reads its whole configuration from the
#     LLAMA_ARG_* environment, so no arguments are passed here
set -euo pipefail

BIN=/opt/bonsai2/bin
MODEL="${BONSAI2_MODEL:-/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf}"
MODEL_DIR="$(dirname "$MODEL")"
KVMC="${BONSAI2_KV_BIAS:-$MODEL_DIR/kv-mean-center.gguf}"
DEFAULT_MODEL="Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf"

log() { echo "[bonsai2] $*" >&2; }

# ---------------------------------------------------------------- GPU check
# Without the container runtime the driver library is simply absent and
# llama-server dies with "libcuda.so.1: cannot open shared object file", which
# says nothing about the actual mistake.  Fail early with the fix instead.
if ! ldconfig -p 2>/dev/null | grep -q 'libcuda\.so\.1' \
   && ! ls /usr/lib/x86_64-linux-gnu/libcuda.so.1 /usr/lib/libcuda.so.1 >/dev/null 2>&1; then
    log "error: the NVIDIA driver is not visible inside this container."
    log "       Start it with the GPU attached:"
    log "         docker run --gpus all ..."
    log "         docker compose up bonsai2-8gb     (uses deploy.resources.reservations.devices)"
    log "       The host needs nvidia-container-toolkit; the CUDA toolkit is not required."
    exit 1
fi

# ---------------------------------------------------------------- weights
if [ ! -f "$MODEL" ]; then
    if [ "${BONSAI2_AUTODOWNLOAD:-1}" = "1" ]; then
        repo="${BONSAI2_HF_REPO:-sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF}"
        url="https://huggingface.co/${repo}/resolve/main/$(basename "$MODEL")?download=true"
        log "weights not found at $MODEL"
        log "downloading 5.85 GiB from ${repo} (once; it stays on the volume)"
        mkdir -p "$MODEL_DIR"
        # --continue-at - resumes a partial download if the volume already has one
        curl -fL --retry 3 --retry-delay 5 -C - -o "${MODEL}.part" "$url"
        # 5.85 GiB is worth verifying; the repo publishes SHA256SUMS
        sums="$(mktemp)"
        if curl -fsSL -o "$sums" \
              "https://huggingface.co/${repo}/resolve/main/SHA256SUMS?download=true" 2>/dev/null; then
            want="$(awk -v f="$(basename "$MODEL")" '$2 == f || $2 == "*"f {print $1}' "$sums")"
            if [ -n "${want:-}" ]; then
                got="$(sha256sum "${MODEL}.part" | awk '{print $1}')"
                if [ "$got" != "$want" ]; then
                    log "error: checksum mismatch for the downloaded weights"
                    log "       expected $want"
                    log "       got      $got"
                    rm -f "${MODEL}.part"
                    exit 1
                fi
                log "weights checksum verified"
            else
                log "warning: SHA256SUMS has no entry for $(basename "$MODEL"); skipping verification"
            fi
        else
            log "warning: could not fetch SHA256SUMS; skipping verification"
        fi
        rm -f "$sums"
        mv "${MODEL}.part" "$MODEL"
        log "weights ready: $MODEL"
    else
        log "error: weights not found: $MODEL"
        log "       mount a volume at ${MODEL_DIR}, or set BONSAI2_AUTODOWNLOAD=1"
        exit 1
    fi
fi

# ------------------------------------------- KV calibration bias (required)
# --kv-mean-center is not optional on this model: without it output quality
# degrades.  The bias is specific to the model AND the cache settings, and the
# server refuses a mismatched one.
if [ ! -f "$KVMC" ]; then
    if [ "$(basename "$MODEL")" = "$DEFAULT_MODEL" ] && [ -f /opt/bonsai2/kv-mean-center.gguf ]; then
        log "installing the calibrated KV bias shipped with this image"
        cp /opt/bonsai2/kv-mean-center.gguf "$KVMC"
    else
        log "no bias for this model; calibrating (one-off, a few minutes)"
        calib="$(mktemp)"
        # Deterministic synthetic corpus: cycling the same sentences keeps the
        # result reproducible without pulling python into the image.  Pass your
        # own text by generating the bias yourself with scripts/make-kv-bias.sh.
        : > "$calib"
        for _ in $(seq 1 25); do
            cat >> "$calib" <<'CORPUS'
The quick brown fox jumps over the lazy dog and this sentence contains every letter of the alphabet.
Artificial intelligence systems process natural language by tokenizing text into smaller units and learning statistical patterns.
A transformer uses self-attention to weigh the relevance of each token against every other token in the sequence.
Quantization reduces numerical precision of model weights, trading a little accuracy for large memory savings.
Memory bandwidth is often the limiting factor for token generation, since every weight is streamed per token.
Prompt processing is compute bound, so throughput scales with available floating point operations.
The KV cache grows linearly with context length, which is why quantizing it enables longer conversations.
Code review checks input validation, authentication boundaries, error handling, resource cleanup and cryptography.
CORPUS
        done
        mkdir -p "$(dirname "$KVMC")"
        "$BIN/llama-kv-mean-center" -m "$MODEL" -f "$calib" -fa on -ctk q4_0 -o "$KVMC" >&2
        rm -f "$calib"
        log "bias ready: $KVMC"
    fi
fi

# ---------------------------------------------------------------- serve
export LLAMA_ARG_MODEL="$MODEL"
export LLAMA_ARG_KV_MEAN_CENTER="$KVMC"

log "starting llama-server (ctx=${LLAMA_ARG_CTX_SIZE:-?} kv=${LLAMA_ARG_CACHE_TYPE_K:-?} port=${LLAMA_ARG_PORT:-?})"
exec "$BIN/llama-server" "$@"
