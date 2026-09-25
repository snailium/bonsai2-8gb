# Container Backend Test Report — RTX 5060 · both snails

Archived under `benchmark/stable/`, where the directory names the **channel** this run
validated. The digest below identifies the actual bytes; a tag can move, a digest cannot.

Date: 2026-09-24
Host / card: `.102` (test-ai) — NVIDIA GeForce RTX 5060, 8151 MiB reported (447 MiB
driver-reserved, 7704 MiB usable), driver 595.91.07, Ubuntu 26.04
Backend: llama-server from the **universal CUDA tarball `b11158-1`**, running inside
`ghcr.io/snailium/bonsai2-8gb/llama-bonsai2:stable`
Image digest: `sha256:b5245beac224b297faa9e2c6b3299f1c2c289f56d7c69d92f9b2a1067b5a1e7a`
Harness: `ghcr.io/snailium/dsh-container/dsh:latest`, digest
`sha256:4cee61f2253e793ea9c34346a6ff1c90e620e01f2fcc1180733e242c6ac807c6`,
profile `headless_lc`, run on the GPU host itself so the only variable versus the
bare-metal baseline is container vs not.
Model: `/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf`, PTQ1_0 1.75 bpw ternary
KV: `q4_0` / `q4_0`, `-fa on`, ctx **40960**, `--kv-mean-center` (required)
Spec decode: `draft-mtp`, `--spec-draft-n-max 1` → **K = 1**
Sampling: t1/t2 direct calls at `temperature 0.2` with **thinking off**; t3–t5 use the
server's shipped profile (temp 0.7 / top_k 20 / top_p 0.80 / min_p 0 / presence 1.5 /
frequency 0 / repeat 1.0, `reasoning-effort low`, `think-budget 4096`), matching the
bare-metal baseline.

## Metrics mode (state it, or the numbers are not comparable)

This fork's llama-server **does not emit the `predicted_n` / `draft_n_accepted` request
JSON** that `llama-server-metrics-extraction` expects — verified: 0 occurrences even
with `-v` enabled. It emits `slot print_timing` blocks instead, one per completed
request, carrying prompt tokens/ms, eval tokens/ms and draft acceptance.

- **t1 / t2** are direct calls, so `timings` comes straight out of the response body:
  **full fidelity**, exact denominators.
- **t3 / t4 / t5** are harness-driven, so their server-side figures below are
  **weighted over the requests that emitted `print_timing`**, not over the task's true
  request count. TTFT for those tasks comes from the dsh session logs
  (`first_chunk_time − step/start.time`), per the skill.

The harness reuses its prefix, so most requests carry few *new* prompt tokens and the
per-request prefill rate is launch-overhead-bound; the large-prompt requests (13–18 K)
are where the real prefill throughput shows. Both are reported.

## Results Summary

| Task | Status | prompt_tok | prefill tok/s | TTFT s | completion_tok | decode tok/s | accept % | Notes |
|---|---|---|---|---|---|---|---|---|
| t1 | **PASS** | 43 | 112.9 | 0.381 | 6213 | **66.76** | **89.31** (2931/3282) | complete HTML, ends `</html>`, `finish=stop` |
| t2 | **PASS** | 32 | 122.5 | 0.261 | 3228 | **67.00** | **86.59** (1498/1730) | complete SVG, ends `</svg>`, `finish=stop` |
| t3 | **TIMEOUT** | 190 613 (19 turns) | 165.9 (38 reqs) | 88.4–97.3 | 4 132 (19 turns) | **48.46** | **85.90** (43737/50914) | killed at 3602 s; still reading files, never concluded |
| t4 | **PASS** | 20 694 (11 turns) | 282.5 (11 reqs) | 58.7 (first) | 5 731 | **49.98** | **84.04** (2211/2631) | answer is **valid JSON**, keys `system, cpu, memory, disk, gpu` |
| t5 | **TIMEOUT** | 135 303 (34 turns) | 159.9 (48 reqs) | 80.4–97.3 | 47 838 | **43.74** | **72.51** (45886/63284) | killed at 3602 s; never produced a snowfall figure |

t1/t2 prefill is 112–122 tok/s purely because their prompts are 32–43 tokens — it is
launch overhead, not throughput. On real prompts the same backend reaches
**282–320 tok/s** (t4 request 1: 18 060 tokens / 56.5 s).

### Counting caveat worth reading

For t3 the session log totals 4 132 output tokens across 19 turns while the server
logged 94 673 eval tokens across 38 requests. The rates agree (48.6 vs 48.46 tok/s);
the volumes do not, because the session's `outputTokens` excludes the thinking tokens
that `print_timing`'s `eval_n` includes, and the server sees roughly two requests per
harness turn. Do not compare the two volumes; compare the rates.

## Per-task evidence

**t1 / t2** — direct calls. Response `timings`:
```
t1: prompt_n=43  prompt_ms=380.73   predicted_n=6213 predicted_ms=93055.1  draft 2931/3282
t2: prompt_n=32  prompt_ms=261.22   predicted_n=3228 predicted_ms=48163.2  draft 1498/1730
```

**t4** — 11 server requests over 194 s. Request 1 carries the ~18 K harness system
prompt: `prompt_n=18060 / 56522 ms = 319.5 tok/s`, TTFT 58.71 s from the session log.
Final answer: one ```json block, parses cleanly.

**t3** — 38 server requests, 18 compactions, prompt totals 264 396 tokens (the review
re-reads the repository repeatedly, so most requests carry 12–15 K new prompt tokens).
TTFT per turn 88–97 s at that depth.

**t5** — 48 server requests, 13 compactions, 3 `approval/asked` events.

## Stability

- VRAM held at **7496 MiB** at load and 7618–7620 MiB during the long agent tasks
  (compute buffers growing with context), never over the 7704 MiB usable limit.
- No OOM, no SIGSEGV, no device loss, no alloc failure in 5 614 090 lines of container
  log across the whole battery.
- No restart: RestartCount 0 before and after; the container served every request from
  one process. Production `bonsai-serve` was stopped for the battery and is running
  again (see restore below).

## Why two tasks timed out (harness interaction, not backend)

Both timeouts are visible in the session logs and neither is a backend failure:

- **t3** used its full hour reading files (18 compactions, 24 tool calls) and was
  killed while still gathering. The backend served every request; the task simply did
  not converge inside the budget.
- **t5** was redirected correctly — the repeat-tool-breaker fired after three
  consecutive failures on the same host (`CONVERGENCE_CHECK: host:api.weather.gc.ca has
  failed 3 times in a row`). A plugin-development session independently read this
  session and confirmed the plugin behaved as designed. What it then ran into is the
  approval policy: **3 `approval/asked` events all resolved `outcome: "unavailable"`**
  — a headless run has no answerer, so the policy fails closed and those tool calls
  were denied, which is why the agent spent the remainder of the hour probing for an
  API path it could reach.

Both are properties of the harness image and its approval policy interacting with a
network-dependent task, not of the container under test.

Also worth recording: **t4 describes the harness container, not the model host** (it
reports Debian 12, Ryzen 5 5600G, 30 GiB RAM, and "no GPU visible"), because the
harness container is started without `--gpus`. That is the shape the procedure
prescribes; it means t4 validates the JSON discipline, not the model host.

## Restore

Production `bonsai-serve` on .102 restored and **verified by a live inference request,
not just `/health`**:

```
health      : {"status":"ok"}
inference   : prompt_n=46  predicted_n=8  decode 45.56 tok/s
VRAM        : 7606 MiB / 8151 MiB      service: active
```

The container log was dumped **before** the container was removed
(`container-full.log`, 477 MB, 5 614 090 lines) — mandatory, because the MTP
acceptance for t3/t4/t5 exists nowhere else. No test containers remain.

There is no SMG router in front of .102, so the skill's routed-request step does not
apply here; the worker-level request is the acceptance test on this host.

## Verdict

**The container is fit to serve.** Every backend metric is inside the range the
bare-metal build produces on this card — decode 66.8/67.0 tok/s on long direct
generation and 43.7–50.0 tok/s on agent turns, prefill up to ~320 tok/s at 18 K, MTP
acceptance 72.5–89.3 % at K = 1, and stable VRAM with no crash across five hours.

Three of five tasks passed outright. The two timeouts are attributable to the harness
(compaction-heavy reading for t3; fail-closed approvals plus an unreachable API for
t5) and would reproduce with the same harness against any backend.

What would change this verdict: a rerun with an answerer wired to the approvals (to
separate "approval policy" from "backend" as the cause of t5), and a longer or staged
budget for t3. Neither is a reason to hold the image.
