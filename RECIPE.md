# Ternary Bonsai 2 27B on an 8 GB NVIDIA card — working recipe

Measured on an **RTX 5060 8 GB** (sm_120), Ubuntu 26.04, driver 595.91.07.

Result: **65–73 tok/s decode at 32K context**, with lossless MTP speculative
decoding. Baseline for the same card on the stock PrismML release binary was
39.6 tok/s.

---

## What you need

| Item | Where | Size |
| --- | --- | ---: |
| `bin/` (this package) | here | 258 MB |
| `Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf` | `sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF` | 5.87 GiB |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf` (optional, no MTP) | `prism-ml/Ternary-Bonsai-2-27B-gguf` | 5.54 GiB |

Only NVIDIA's driver is required — the CUDA runtime is not bundled, see caveats.

---

## Quick start

```bash
# 1. get the model
hf download sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF \
    Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf --local-dir ~/models/bonsai2

# 2. build the KV calibration bias (once, per model)
./scripts/make-kv-bias.sh ~/models/bonsai2/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf

# 3. serve
./scripts/serve.sh
```

Then:

```bash
curl http://127.0.0.1:18199/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Write a Python fibonacci function."}],"max_tokens":300,"temperature":0}'
```

---

## The flags that matter

```
GGML_CUDA_BATCH_INVARIANT=1      # makes MTP strictly lossless (greedy byte-identical)
-m  <lean gguf>
-ngl 99 -fa on
-c 32768                          # verified working on 8 GB
-np 1                             # MTP requires a single slot
-ctk q4_0 -ctv q4_0               # required: keeps 32K inside 8 GB
--kv-mean-center <bias.gguf>      # recovers q4_0 K-cache accuracy; hard requirement
--reasoning-effort medium         # IMPORTANT, see below
--spec-type draft-mtp --spec-draft-n-max 1   # see note below
--temp 0.7 --top-p 0.80 --top-k 20 --presence-penalty 1.5
```

### `--reasoning-effort medium` is not optional

The chat template defaults to `xhigh`, which injects a "think carefully through
the task" system line. On a quantized 27B that becomes a runaway loop: a
controlled experiment (3 tasks × 2 caps × 2 runs, greedy) found the default
returns **nothing at all** on all three tasks at a 4096-token cap, and **still
returns nothing** for one task at 16384. `medium` completes all three in 45–124 s.

`medium` is the only setting that injects no instruction.

### `--spec-draft-n-max`: 1 or 2?

This is the number of tokens the draft head proposes per step. Acceptance falls
as it rises, and throughput is **not** monotonic — measured on an RTX 5060 at
`-c 32768`, lean file, 3 runs each:

| `--spec-draft-n-max` | decode tok/s | acceptance | generated/request |
| ---: | ---: | ---: | ---: |
| **1** | 68.7 | 0.851 | 161 |
| **2** | **70.0** | 0.756 | 238 |
| 3 | 68.2 | 0.666 | 299 |

`2` was ~2% faster on our card; the upstream author measured `1` as best on an
RTX 3060 and noted `n-max 2` loses to head-off past ~16K context. The difference
is small and workload-dependent, so **sweep it on your own card** rather than
trusting either number. `1` is the safer default — it has the highest acceptance,
so it degrades most gracefully if your workload drafts poorly.

Note that production `b70-sycl` uses `3`, but that is a different model
(Qwen3.8-27B with its own MTP head), so the value is not transferable.

### Sampling

The template's `presence_penalty` default is `0.0`, which is wrong for this
model — it produces repetition loops. Use **1.5** (instruct mode, thinking off).

---

## Verified numbers

`llama-bench -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -p 512 -n 128 -r 3 -d 0`:

| Build | tg128 |
| --- | ---: |
| stock PrismML `b10685` release | 39.56 |
| **this package** | **54.31** (+37%) |

Server, with MTP, `-c 32768`, `GGML_CUDA_BATCH_INVARIANT=1`:

| Workload | decode tok/s | draft acceptance |
| --- | ---: | ---: |
| code | 70.7 | 0.85 |
| bash | 68.9 | 0.78 |
| prose | 64.6 | 0.67 |

At `-c 16384` the figures are identical (73.2 / 68.8 / 64.3), so 32K is free at
this depth. VRAM: **7284 MiB used, 422 MiB free** at 32K.

---

## Caveats — read before deploying

**1. NVIDIA driver only, but the CUDA runtime is NOT bundled.**
The binaries link `libcudart.so.12`, `libcublas.so.12`, `libcublasLt.so.12` from
the system. On Ubuntu these come from `libcudart12` and `libcublas12`
(`apt install libcudart12 libcublas12`). glibc 2.35+ required.

**2. Built for `sm_120` (Blackwell) only.**
This will **not** run on Ampere (sm_86) or Ada (sm_89). If your card is older,
rebuild — see `BUILD.md`.

**3. The binaries carry an absolute RUNPATH** pointing at the build machine's
path. They still run from another location because the libraries sit alongside
them, but if you hit a library error, set:

```bash
export LD_LIBRARY_PATH="$(pwd)/bin:$LD_LIBRARY_PATH"
```

**4. Zero draft acceptance is the failure signature for MTP.**
If MTP appears to give no speedup, check the server log for
`draft acceptance =`. A value near 0.00 means it is pure overhead (decode falls
back to ~54 tok/s). We hit this once from a **stale `llama-server` process**
contending for the GPU; restarting fixed it. It presents as "MTP doesn't help",
not as an error.

**5. `kv-mean-center` bias is model-specific and rotation-state-specific.**
It must be regenerated per model, and calibrated with **matching** cache
settings. A mismatch makes the server refuse to start (deliberate safety check):

```
bias file ... was calibrated with the K-cache rotation inactive,
but it is active for this context - recalibrate with matching cache settings
```

Generate it with `-fa on -ctk q4_0` to match the serving config.

**6. `llama-bench` cannot test MTP.** It rejects `--spec-type`:

```
error: invalid parameter for argument: --spec-type
```

MTP is a *server* feature. To measure it, run `llama-server` and read
`timings.predicted_per_second` from the response, or grep the log for
`draft acceptance =`. `llama-bench` measures the kernel only — which is still
worth doing (it is how the +37% figure was obtained).

**7. Counting tokens wrong gives a 4x error.** This model streams its thinking
through `delta.reasoning_content`, **not** `delta.content`. A client that counts
only `content` reports ~9.6 tok/s where the real figure is ~39. Count both, and
keep the two separate.

**8. Streaming responses carry no `usage` block by default.** Without

```json
"stream_options": {"include_usage": true}
```

you get no `prompt_tokens`, so prefill rate cannot be computed from server-side
counts. Send it on every streaming request you intend to measure.

**9. Two servers on one GPU silently halve throughput.** We hit this: a stale
`llama-server` from an earlier run was still holding the card. Nothing errors —
you just get roughly half the tokens and, with MTP, an acceptance rate near zero.
Before benchmarking, check:

```bash
pgrep -af llama-server     # should list exactly one
nvidia-smi                 # confirm the VRAM figure matches your config
```

**10. Do not use stock llama.cpp or Ollama.**
Bonsai 2 needs the PrismML fork lineage. Stock llama.cpp rejects `PTQ1_0`/`PQ2_0`
outright, and a legacy `Q2_0` file loads silently and emits **gibberish**.

**11. The vision tower does not fit an 8 GB card.** Adding `--mmproj` (604 MiB)
causes a hard OOM at load; even when it loads, usable context collapses to a few
thousand tokens. The recipes here are text-only. On 10 GB+ it becomes viable —
but MTP and the vision tower compete for the same headroom.

**12. `-c` ceiling is cuBLAS-workspace-bound, not KV-bound.**
On 8 GB without MTP we measured 49152 working and 65536 failing on
`cublas_workspaces` allocation. Reducing `-ub` does not help.

---

## Environment notes

- Built from `sudoingX/llama.cpp` branch **`bonsai2`** at commit **`dcc3be7`**,
  which is PrismML fork `prism` + the PTQ1_0 kernel (PR #218) + the qwen35 MTP
  Hadamard-embedding fix (PR #217 / #205).
- `pushd`/`cd` into `bin/` before running, or use the scripts.
- Ports: this recipe uses **18199**. Avoid 8080 — on some systems it is taken.

---

## Licence

Binaries: llama.cpp MIT. Model weights: Apache 2.0 (Qwen3.8-27B by Alibaba
Cloud; Ternary Bonsai 2 by PrismML; graft by sudoingX). Not affiliated with any
of them.
