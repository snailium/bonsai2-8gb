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
# 1. unpack the binaries — pick the package for your card (see caveat 2)
tar xzf bonsai2-universal.tar.gz        # any CUDA card, sm_75 -> sm_120
# tar xzf bonsai2-5060-sm120-only.tar.gz  # smaller, RTX 50-series only
cd bonsai2-universal

# 2. get the model weights
hf download sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF \
    Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf --local-dir ~/models/bonsai2

# 3. build the KV calibration bias (once, per model).
#    The script takes the model path and writes kv-mean-center.gguf beside it,
#    which is where serve.sh looks for it.
./scripts/make-kv-bias.sh ~/models/bonsai2/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf

# 4. serve — golden config: -c 40960, effort=low, budget=4096
#    MODEL_DIR defaults to ~/models/bonsai2; override it if your weights live elsewhere.
./scripts/serve.sh
```

`serve.sh` defaults to the **agent** reasoning profile. Override with
`REASONING_EFFORT` / `REASONING_BUDGET`, and for single-shot generation pass
`--reasoning off` — see the reasoning section below.

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
-c 40960                          # golden: largest context that loads with MTP
-np 1                             # MTP requires a single slot
-ctk q4_0 -ctv q4_0               # required: keeps 32K inside 8 GB
--kv-mean-center <bias.gguf>      # recovers q4_0 K-cache accuracy; hard requirement
--spec-type draft-mtp --spec-draft-n-max 1   # see note below
--temp 0.7 --top-p 0.80 --top-k 20 --presence-penalty 1.5
```

Reasoning is **not** a single setting — pick by workload (see the next section).

---

## Reasoning: two profiles, not one setting

We tested this backend both as a plain text generator and as an agent backend. The two
want opposite things, and there is no single value that serves both.

| Workload | Server flag | Client |
| --- | --- | --- |
| **Single-shot generation** — "write me an HTML page / an SVG / a document" | `--reasoning off` | — |
| **Agentic / tool-using** — research, review, multi-step work | `--reasoning-effort low --reasoning-budget 4096` | — |

### Generation tasks: turn thinking off

These have no planning phase — the model writes. Thinking spends tokens the document
needs, and on this model it more often degenerates than helps. Measured with thinking
off, both generator tasks passed with **0 reasoning frames** and correctly closed output:

| Task | reasoning frames | completion tokens | decode | output closed |
| --- | ---: | ---: | ---: | --- |
| HTML page | **0** | 6,731 | 66.2 tok/s | yes (`</html>`) |
| SVG diagram | **0** | 2,423 | 67.4 tok/s | yes (`</svg>`) |

### Agent tasks: `low` with a bounded budget

Agentic work does benefit from a plan, but this model over-deliberates on
knowledge-dense prompts — we measured a case where **86% of a 24,508-token response was
thinking** and the answer never arrived. `low` fixes that with an explicit instruction
from the chat template:

> "Reasoning effort is set to low. **Keep your thinking brief and focused, moving
> directly to the conclusion without unnecessary elaboration.**"

`medium` injects **no instruction at all**, which is why the template's `xhigh` default is
so damaging. But `medium` alone still over-thinks: an unbounded `medium` run spent 86% of
its budget thinking and failed to emit its document.

### Why a budget, and why 4096

The budget is a **hard cut** — the sampler forces the end-of-thinking sequence the moment
the count is reached, so the model answers from whatever plan it had. Verified exact: a
budget of 2,048 stopped thinking at **2,064–2,070 tokens** across five runs (the ~20-token
overshoot is the sampler letting a multi-byte character finish). There is no graceful
wind-down.

**4096, not 2048**, because the cut lands early at 2,048 on tasks that genuinely need to
plan. 4,096 leaves more room while staying **completely inert where thinking is not
needed** — a task that wanted no plan used only 215 thinking tokens and never approached
either value.

**16,384 does nothing at all.** We measured natural thinking of 3,000–8,700 tokens on
these tasks, so a 16K budget never fires and is equivalent to no budget. A budget larger
than the model's natural thinking length is a no-op.

### Only one direction works from a single server

If you need both profiles from one server, run with thinking **on** and disable it per
request:

```json
"chat_template_kwargs": {"enable_thinking": false}
```

**The reverse does not work.** With `--reasoning off` on the server, a client sending
`reasoning_effort: "high"` still gets **0 reasoning frames** — the server flag wins. We
verified both directions:

| Server | Client | Result |
| --- | --- | --- |
| `--reasoning off` | `reasoning_effort: high` | **0 reasoning** (server wins) |
| `--reasoning-effort low` | *(nothing)* | 28 reasoning frames |
| `--reasoning-effort low` | `enable_thinking: false` | **0 reasoning** |

### Never leave the template default

The chat template defaults to `xhigh`, which injects a "think carefully through the
task, validate key assumptions, consider plausible alternatives" system line. On a
quantized 27B that becomes a runaway loop. A controlled upstream experiment
(3 tasks × 2 caps × 2 runs, greedy) found the default returns **nothing at all** on
all three tasks at a 4096-token cap, and still nothing for one task at 16,384.

`medium` is the only level that injects **no** instruction; `low` injects the brevity
instruction quoted above. Either is safe. The default is not.

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

Server-side decode with MTP, `GGML_CUDA_BATCH_INVARIANT=1`, short prompts, measured at
`-c 32768` (context depth barely affects short-prompt decode at this size):

| Workload | decode tok/s | draft acceptance |
| --- | ---: | ---: |
| code | 70.7 | 0.85 |
| bash | 68.9 | 0.78 |
| prose | 64.6 | 0.67 |

At `-c 16384` the figures are identical (73.2 / 68.8 / 64.3), so raising context from 16K
to 32K costs nothing at this depth. VRAM: **7,284 MiB used, 422 MiB free** at 32K,
**7,508 MiB used, 198 MiB free** at the golden 40,960.

Full per-task figures at 40,960 — including prefill, TTFT and agent-run decode — are in
[the battery results](#battery-results-at-c-40960-55-pass).

---

---

## Golden configuration: `-c 40960`

**`-c 40960` is the recommended setting for this card.** It is the largest context that
loads with MTP, and at it **all five battery tasks pass**.

| | |
| --- | --- |
| context | **40,960** |
| VRAM | **7,508 MiB used, 198 MiB free** |
| measured ceiling | 49,152 fails (`cudaMalloc` out of memory) |

The two next steps up and down, measured on this card:

| `-c` | with MTP | without MTP |
| ---: | --- | --- |
| 32,768 | loads, 7,284 MiB | — |
| **40,960** | **loads, 7,508 MiB ← golden** | — |
| 49,152 | **fails** | — |
| 65,536 | fails | loads, 7,268 MiB — **but output collapses, see caveat 12** |
| 81,920 | — | loads, 7,636 MiB — same collapse |
| 90,112 | — | fails |

Using 32,768 instead costs nothing in speed but leaves agent tasks fighting the wall:
at 32K the T5 research task needed 7–25 compactions per run (1–4 of them failing), and the
T3 review could not complete at all.

## Battery results at `-c 40960` — 5/5 PASS

RTX 5060 8 GB, MTP `n-max 1`, `maxTokens: 8192`, driven through an agent harness.

| Task | Thinking | Status | Decode | Notes |
| --- | --- | --- | ---: | --- |
| t1 — single-file HTML page | **off** | **PASS** | 65.9 tok/s | 3,776 tok, `</html>` closed |
| t2 — SVG diagram | **off** | **PASS** | 67.4 tok/s | 3,642 tok, `</svg>` closed |
| t3 — 27-file security review | low / 4096 | **PASS** | 38.7 tok/s | 31 tool calls, 5,478-char report |
| t4 — host configuration | low / 4096 | **PASS** | 45.1 tok/s | valid JSON, exit 0 |
| t5 — multi-source research | low / 4096 | **PASS** | 33.8 tok/s | 46 tool calls, answered correctly |

### Generation tasks (t1, t2)

| Task | prefill | TTFT | decode | completion | output closed |
| --- | ---: | ---: | ---: | ---: | --- |
| t1 HTML | 28.6 tok/s | 1.51 s | 65.9 tok/s | 3,776 | yes |
| t2 SVG | 54.0 tok/s | 0.59 s | 67.4 tok/s | 3,642 | yes |

Both ran with `enable_thinking: false` and produced **0 reasoning frames** — the entire
output budget went to the document.

### Agent tasks (t3, t4, t5)

Weighted over all requests in each run:

| Task | requests | prefill | TTFT | decode | wall clock |
| --- | ---: | ---: | ---: | ---: | ---: |
| t3 | 17 | 124.8 tok/s | 113.1 s | 38.7 tok/s | ~60 min (hit a 1 h cap on the first attempt) |
| t4 | 5 | 119.6 tok/s | 11.3 s | 45.1 tok/s | short |
| t5 | 46 | 122.7 tok/s | 86.9 s | 33.8 tok/s | ~35 min |

### Why agent decode is lower than generation decode

Agent runs decode at 33–45 tok/s against 66–67 for single-shot generation. The difference
is context depth, not a config problem: the agent runs carry 9–15K token prompts, and
decode falls with context length on this card. Prefill itself stays healthy at
120–125 tok/s throughout.

**Every agent turn re-prefills the whole prompt.** Context trimming shadows a span
mid-conversation, which invalidates the cache for everything after it, so the next request
re-evaluates ~9,000–15,000 tokens from scratch — roughly **72 seconds of prefill per tool
call** at 129 tok/s. That is the dominant wall-clock cost on long agent tasks, and it is
inherent to surviving in a 40K window.

## What the 32K configuration could not do

The same battery at `-c 32768`:

| Task | at 32K | at 40K |
| --- | --- | --- |
| t1, t2 | PASS | PASS |
| t3 | could not complete (context exhausted) | **PASS** |
| t4 | PASS | PASS |
| t5 | 1 pass in 5 runs — the pass was an outlier | **2 passes in 2 runs** |

### T5 at 32K: five runs, five configurations, one cause

Context capacity, and nothing else. Varying only the reasoning configuration:

| # | Configuration | steps | tool calls | compactions (failed) | turn ended |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | `medium`, no budget | 19 | 18 | 5 (0) | **completed — 153.4 cm** |
| 2 | `medium` + budget 16,384 | 30 | 33 | 25 (**4**) | killed at 60 min |
| 3 | `medium` + budget 16,384 | 19 | 19 | 12 (**2**) | `max-tokens` |
| 4 | thinking **off** | 15 | 20 | 9 (**4**) | `max-tokens` |
| 5 | `low` + budget 2,048 | 14 | 13 | 7 (**1**) | `max-tokens` |

Run 1 is the only completion and it is an outlier. Runs 2–5 all hit the 32,768-token wall,
ending `turn/end: {"kind": "max-tokens"}` — the context, not an output cap and not a guard
block. Compaction failed the same way every time:

```
"summary is not smaller than the shadowed content (1180 estimated framed tokens >= 1180)"
```

The summarizer cannot produce a summary smaller than the region it is condensing. That is
a structural limit of surface compaction, and it is why the extra 8K matters: at 40,960 the
same task needed **1 compaction with zero failures**.

### What was ruled out — do not re-litigate these

| Hypothesis | Verdict |
| --- | --- |
| Thinking budget too small or too large | **Ruled out** — 2,048 / 4,096 / 16,384 / none all failed at 32K |
| `reasoning-effort` level | **Ruled out** — `medium` and `low` both failed at 32K |
| Thinking on vs off | **Ruled out** — both failed at 32K |
| `maxTokens` too high | **Partially addressed** — dropping to 8192 removes a pathological case but does not create room |
| Flash-attention build flag missing | **Ruled out** — `q4_0-q4_0` ships in the default kernel set; FA was already active |
| Compaction could be made to work | **No** — the summarizer must fit the region it condenses; more context is the fix |

### Client `max_tokens`: use 8192

On a 40K window a larger output cap races the prompt for the same tokens. We measured a run
where prompt 32,248 + output 520 = 32,768 exactly, ending `max-tokens`: the window was
consumed by prompt **and** output together.

But **8192 is tight for long document generation**. Five runs of the HTML task at identical
settings produced totals of 4,579 / 7,829 / 8,192 / 8,192 / 8,192, and **three of the five
hit the cap without closing `</html>`**. If your workload is long-form output, raise
`max_tokens` to 12K+ and accept a smaller context, or ask for shorter documents.

## Caveats — read before deploying

**1. NVIDIA driver only, but the CUDA runtime is NOT bundled.**
The binaries link `libcudart.so.12`, `libcublas.so.12`, `libcublasLt.so.12` from
the system. On Ubuntu these come from `libcudart12` and `libcublas12`
(`apt install libcudart12 libcublas12`). glibc 2.35+ required.

**2. Two builds — pick the one matching your card.**
The **universal** package covers Turing through Blackwell in a single binary;
the **5060** package is `sm_120` only and smaller.

| Package | Architectures |
| --- | --- |
| `bonsai2-universal.tar.gz` | sm_75, 80, 86, 89, 90, 100, 110, 120 (+ PTX) |
| `bonsai2-5060-sm120-only.tar.gz` | sm_120 only |

`cmake`'s default (non-universal) build emits only the architectures you ask for,
so a binary built for one architecture will **not** run on another — you will get a
load failure or a silent CPU fallback. If you build your own, set
`CMAKE_CUDA_ARCHITECTURES` for your card; see `BUILD.md`, which lists the value per
generation and the three build traps (CUDA 12.4 cannot target Blackwell, a glibc
2.43 `rsqrt` conflict, and `cmake` silently selecting an older `nvcc`).

Check which architecture a binary carries:

```bash
cuobjdump --list-elf bin/libggml-cuda.so.0.21.0
```

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

**12. Do not drop MTP to gain context — the model collapses.**
Removing `--spec-type draft-mtp` roughly doubles the usable window (40,960 → 81,920) but
the model then emits **nothing but `/` characters**, deterministically. Measured:

| Configuration | Result |
| --- | --- |
| 32K + MTP | coherent |
| 32K, no MTP | **all slashes** (reproduced) |
| 64K, no MTP | **all slashes, 3/3 runs** |
| no MTP + `enable_thinking:false` | `content` is **200 consecutive `/`** |
| no MTP, original `PTQ1_0.gguf` | **all slashes** |

It is not the `-mtp-lean` file (the original GGUF behaves identically) and not the
reasoning path (thinking off collapses into `content`). **Keep MTP enabled.**

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
