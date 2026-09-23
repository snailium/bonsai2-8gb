# Battery results — 40,960 vs 32,768

Config identical except `-c`. Model, flags, harness, sampling all the same.

```
GPU      RTX 5060 8 GB, sm_120
Model    Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf
Server   -ngl 99 -fa on -np 1 -ctk q4_0 -ctv q4_0 --kv-mean-center
         --spec-type draft-mtp --spec-draft-n-max 1
         --reasoning-effort low --reasoning-budget 4096
         --temp 0.7 --top-p 0.80 --top-k 20 --presence-penalty 1.5
         GGML_CUDA_BATCH_INVARIANT=1
Client   maxTokens 8192
```

## At 40,960 — 5/5

| task | thinking | result | prefill | TTFT | decode |
| --- | --- | --- | ---: | ---: | ---: |
| t1 HTML page | off | PASS | 28.6 tok/s | 1.51 s | 65.9 tok/s |
| t2 SVG | off | PASS | 54.0 tok/s | 0.59 s | 67.4 tok/s |
| t3 27-file review | low/4096 | PASS | 124.8 tok/s | 113.1 s | 38.7 tok/s |
| t4 host config | low/4096 | PASS | 119.6 tok/s | 11.3 s | 45.1 tok/s |
| t5 research | low/4096 | PASS | 122.7 tok/s | 86.9 s | 33.8 tok/s |

t1/t2 are single-shot (1 request each). t3/t4/t5 are weighted over
17 / 5 / 46 requests respectively. Verify with scripts/04-extract-metrics.py.

## At 32,768 — t1/t2/t4 pass, t3/t5 fail

| task | result | detail |
| --- | --- | --- |
| t3 | **could not complete** | 25 steps, 31 tool calls, 0 chars of report text |
| t5 | **1 pass in 5 runs** — the pass is an outlier | see below |

### t5 at 32K: five runs, five reasoning configs, one cause

| # | config | steps | tool calls | compactions (failed) | turn ended |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | medium, no budget | 19 | 18 | 5 (0) | completed — 153.4 cm |
| 2 | medium + budget 16384 | 30 | 33 | 25 (4) | killed at 60 min |
| 3 | medium + 16384 | 19 | 19 | 12 (2) | max-tokens |
| 4 | thinking off | 15 | 20 | 9 (4) | max-tokens |
| 5 | low + budget 2048 | 14 | 13 | 7 (1) | max-tokens |

Runs 2-5 all end `turn/end: {"kind": "max-tokens"}` at the context ceiling.
The reasoning configuration was varied across its full range and made no
difference: the binding constraint is the window.

### Why the compactions failed

```
summary is not smaller than the shadowed content (1180 estimated framed tokens >= 1180)
```

The summarizer cannot produce a summary smaller than the region it is
condensing. At 40,960 the same task needed 1 compaction, with 0 failures.
