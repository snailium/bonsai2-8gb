# Reproducible evidence pack — RTX 5060 8 GB / Ternary Bonsai 2 27B

Every number in the public write-up, with the command that produced it and the raw
output. Nothing here requires trusting our summary: each claim maps to a script you can
run and a result file you can read.

## What this pack contains

```
scripts/     the exact scripts used — no post-processing
results/     raw captured output (llama-bench tables, VRAM readings, session extracts)
logs/        full session logs for the agent runs, compressed
```

## The five claims

| # | Claim | Where |
| --- | --- | --- |
| 1 | decode **54.31 tok/s**, vs stock release **39.56** (+37%) | `results/bench-tg128.txt` |
| 2 | context ceiling **40960 with MTP**, **81920 without** | `results/context-sweep.txt` |
| 3 | dropping MTP → output collapses to `/` | `results/no-mtp-collapse.txt` |
| 4 | 40K: **5/5 agent tasks pass**; 32K: t3/t5 fail | `results/battery-40k.md`, `results/battery-32k.md` |
| 5 | trim freed ~3.7 万 tokens in t3; guard fired on `host:` in t5 | `results/plugin-activity.md` |

## Environment

```
GPU        RTX 5060 8 GB, sm_120 (Blackwell), driver 595.91.07
OS         Ubuntu 26.04, kernel 7.0.0-31
CUDA       13.1 (/usr/local/cuda-13.1)
Build      sudoingX/llama.cpp branch bonsai2 @ dcc3be7
Model      Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf  (6,297,658,848 B)
```

**Two build prerequisites that are not optional** — see `BUILD-NOTES.md`:
1. CUDA ≥ 12.8 (12.4 cannot target sm_120 at all)
2. a patch to CUDA's `crt/math_functions.h` for the glibc 2.43 `rsqrt` conflict

## How to reproduce

```bash
# 0. build (see BUILD-NOTES.md), then set:
export BIN=/path/to/llama.cpp/build/bin

# 1. kernel-only decode
./scripts/01-bench-tg128.sh "$BIN"

# 2. context ceiling, with and without MTP
./scripts/02-context-sweep.sh "$BIN"

# 3. the no-MTP collapse (the surprising one)
./scripts/03-no-mtp-collapse.sh "$BIN"

# 4. per-task prefill/TTFT/decode from a session log
./scripts/04-extract-metrics.py <session-home> --task t5

# 5. plugin activity (trim elisions, guard messages)
./scripts/05-plugin-activity.py <session-home>
```

Steps 1–3 need the GPU. Steps 4–5 are pure log analysis and run anywhere — they
read either live dsh logs or the copies in `logs/` (see `logs/README.md` for the
one-line unpack step).

## Notes on method

**Decode is context-dependent.** 54.31 is `llama-bench tg128 -d 0` (fresh context). In
agent runs with 9–15K prompts, server-side decode is 33–45 tok/s. Both are reported; they
measure different things.

**`llama-bench` cannot test MTP** — it rejects `--spec-type`. So the 54.31 figure is the
kernel baseline *without* speculation. MTP decode (65–73) was measured through
`llama-server` and is in `results/mtp-decode.txt`.

**Agent runs are single samples.** The battery was run once per configuration. Where a
result could be an outlier we say so — the 32K t5 result (1 pass in 5 runs) is flagged as
an outlier in our own notes.

**Sampling is `temp 0.7`**, not greedy, so run-to-run variance is expected. Where we claim
determinism (the no-MTP collapse) it is because it reproduced across repeated runs and both
model files.
