# bonsai2-8gb

Prebuilt **llama.cpp binaries for Ternary Bonsai 2 27B** on 8 GB NVIDIA cards,
with working MTP speculative decoding.

**Measured: 65–73 tok/s decode at 32K context** on an RTX 5060 8 GB.
The stock PrismML release binary gives 39.6 tok/s on the same card — this build
is **+37% on the kernel alone**, plus another **+18–35% from MTP**.

| Workload | this build + MTP | acceptance |
| --- | ---: | ---: |
| code | 70.7 tok/s | 0.85 |
| bash | 68.9 tok/s | 0.78 |
| prose | 64.6 tok/s | 0.67 |

---

## What's in here

```
bin/                 llama-server, llama-bench, llama-cli, llama-kv-mean-center + shared libs
scripts/serve.sh     serve with the working flags
scripts/bench.sh     reproduce the numbers
scripts/make-kv-bias.sh   generate the required KV calibration bias
RECIPE.md            full explanation of every flag, caveats, and pitfalls
BUILD.md             how to rebuild for a different GPU (Ampere / Ada)
```

Built from [`sudoingX/llama.cpp`](https://github.com/sudoingX/llama.cpp) branch
**`bonsai2`** at commit **`dcc3be7`** — the PrismML fork plus three unmerged fixes:

- **PR #218** — dedicated PTQ1_0 mat-vec kernel (the +37%)
- **PR #217 / #205** — qwen35 MTP Hadamard-embedding fix (without it MTP won't start)
- **PR #220** — GATED_DELTA_NET gather fusion

## Quick start

```bash
# 1. model weights (5.87 GiB) — from Hugging Face
hf download sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF \
    Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf --local-dir ~/models/bonsai2

# 2. required KV calibration bias (once per model)
MODEL_DIR=~/models/bonsai2 ./scripts/make-kv-bias.sh \
    ~/models/bonsai2/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf

# 3. serve
MODEL_DIR=~/models/bonsai2 ./scripts/serve.sh
```

Then hit `http://127.0.0.1:18199/v1/chat/completions`.

See **[RECIPE.md](RECIPE.md)** for the full flag list and why each one matters.

---

## Read these before filing a bug

**This build targets `sm_120` (Blackwell) only.** It will not run on Ampere or
Ada. Rebuild with [BUILD.md](BUILD.md) — it takes ~10 minutes.

**Three things are load-bearing and non-obvious:**

1. **`--reasoning-effort medium`** — the chat template defaults to `xhigh`, which
   on a quantized 27B turns into a runaway thinking loop. In a controlled test it
   returned **nothing at all** on 3/3 tasks at a 4096-token cap, and still nothing
   for one task at 16384. `medium` completes them in 45–124 s.
2. **`--presence-penalty 1.5`** — the template default is `0.0`, which produces
   repetition loops. 1.5 is the value that works.
3. **`--kv-mean-center`** — required companion to `q4_0` KV. The bias is
   model-specific and must be calibrated with matching cache settings, or the
   server refuses to start.

**Zero draft acceptance is the MTP failure signature.** If MTP gives no speedup,
grep the log for `draft acceptance =`. Near 0.00 means pure overhead — we hit
this once from a stale `llama-server` process holding the GPU. It looks like
"MTP doesn't help", not like an error.

---

## Runtime requirements

- NVIDIA driver (recent enough for your card) — **the CUDA toolkit is not needed**
- CUDA runtime libraries from the system: `libcudart12`, `libcublas12`, `libgomp1`
- glibc 2.35+

```bash
sudo apt install libcudart12 libcublas12 libgomp1
```

Binaries carry `RUNPATH=$ORIGIN`, so the package is relocatable — move it
anywhere and it still runs (verified).

---

## Credit

- [PrismML](https://prismml.com) — Bonsai 2 and the llama.cpp fork
- [sudoingX](https://github.com/sudoingX/bonsai2-small-gpu) — the PTQ1_0 kernel,
  the MTP graft, and the measurements this build is based on
- Qwen (Alibaba Cloud) — Qwen3.8-27B and the MTP head
- [unsloth](https://huggingface.co/unsloth) — donor GGUF for the MTP graft

Not affiliated with any of them. Weights are Apache 2.0; the binaries are
llama.cpp's MIT.

---

## Measured on

RTX 5060 8 GB (8151 MiB, 447 MiB driver-reserved → 7704 MiB usable), driver
595.91.07, Ubuntu 26.04, kernel 7.0.0-31.

Numbers are reproducible via `scripts/bench.sh`. Your card will differ — see
`sweeps/` in the kernel repo for other hardware (RTX 3060 12 GB, 3060 Ti 8 GB,
4070).
