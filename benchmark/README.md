# benchmark

Evidence for published image tags. One directory per **floating tag**, holding the
report and the raw artifacts from the run behind it.

```
stable/
  REPORT.md                        t1-t5: per-task prefill, TTFT, decode, MTP acceptance
  t1-output.html                   t1's answer, code fence stripped
  t2-output.svg                    t2's answer, code fence stripped
  t3-session-b914bb30.v3.jsonl     the harness session for t3, decompressed
  t3-session-b914bb30.v3.jsonl.zstd    ... and exactly as dsh wrote it
  t4-session-3cc3d8c5.v3.jsonl(.zstd)
  t5-session-0d5af379.v3.jsonl(.zstd)
```

## Read the digest, not the directory name

A floating tag moves, so the directory name tells you which *channel* a run was
validated for — not which bytes. The report records the exact digest it ran, and that
is the authoritative identity:

```
stable/  ->  ghcr.io/snailium/bonsai2-8gb/llama-bonsai2@sha256:b5245beac224b297faa9e2c6b3299f1c2c289f56d7c69d92f9b2a1067b5a1e7a
```

When a new build is promoted, add a directory rather than overwriting an existing one.
A directory named after a dated tag is unambiguous, because those never move.

## Reading a session

These are dsh's own records: one JSON object per line, plus a `.lock` sibling that is
not part of the log.

```bash
zstd -dc -- t5-session-0d5af379.v3.jsonl.zstd | head
```

Both forms are kept on purpose — the `.zstd` is byte-exact to what dsh wrote, the
`.jsonl` is there so the file can be read and searched on GitHub without any tooling.
Event types worth grepping for:

| event | what it tells you |
| --- | --- |
| `tool/call`, `tool/result` | what the agent actually did, step by step |
| `assistant/message` | per-turn `usage` and the stream timings used for TTFT / decode |
| `step/start` | the anchor for TTFT (first chunk time minus this) |
| `compaction/*` | how often the harness had to summarise the context |
| `agent/inbox/spliced` | harness steering, e.g. the repeat-tool-breaker redirect |
| `approval/asked`, `approval/decided` | tool approvals; `unavailable` means no answerer, so it fails closed |

## What is in a report

Every row carries prefill rate, TTFT and decode rate, as required. When speculative
decoding is on, the draft acceptance rate is reported too, together with K — acceptance
rates are only comparable at equal K.

Two honesty notes that apply to any run recorded here:

- the server this fork ships does **not** emit the per-request `predicted_n` /
  `draft_n_accepted` JSON, so harness-driven tasks report figures weighted over the
  requests that emitted `slot print_timing`, not over the task's true request count;
- the harness reuses its prefix, so a per-request prefill rate on a short prompt is
  launch overhead, not throughput. The large-prompt requests are where it shows.
