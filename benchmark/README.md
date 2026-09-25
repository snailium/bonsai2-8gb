# benchmark

Evidence for published images. One directory per **dated build tag**, holding the
report and the raw artifacts from the run behind it.

```
server-dev-b11158-1-20260924-2006/
  REPORT.md                            t1-t5: per-task prefill, TTFT, decode, MTP acceptance
  t1-output.html                       t1's answer, code fence stripped
  t2-output.svg                        t2's answer, code fence stripped
  t3-session-b914bb30.v3.jsonl         the harness session for t3, decompressed
  t3-session-b914bb30.v3.jsonl.zstd    ... and exactly as dsh wrote it
  t4-session-3cc3d8c5.v3.jsonl(.zstd)
  t5-session-0d5af379.v3.jsonl(.zstd)
```

## Why the directory is a dated tag and not a channel name

`stable` and `server-dev` are **pointers**: they move as new builds are promoted, so a
directory named after one of them would silently stop describing the run it contains.
The dated tags never move — `server-dev-b11158-1-20260924-2006` always resolves to the
same digest — so the directory name identifies the build, and a new build adds a
directory rather than overwriting one.

The report repeats the digest it actually ran, which is the authoritative check if a
tag is ever re-pushed. For the run archived here the two agree:

```
server-dev-b11158-1-20260924-2006  ->  ghcr.io/snailium/bonsai2-8gb/llama-bonsai2
                                    @  sha256:b5245beac224b297faa9e2c6b3299f1c2c289f56d7c69d92f9b2a1067b5a1e7a
```

The tag scheme itself lives in [.devops/README.md](../.devops/README.md).

## Reading a session

These are dsh's own records: one JSON object per line, with a `.lock` sibling that is
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
| `assistant/message` | per-turn `usage` and the stream timings behind TTFT / decode |
| `step/start` | the anchor for TTFT (first chunk time minus this) |
| `compaction/*` | how often the harness had to summarise the context |
| `agent/inbox/spliced` | harness steering, e.g. the repeat-tool-breaker redirect |
| `approval/asked`, `approval/decided` | tool approvals; `unavailable` means no answerer, so it fails closed |

## What is in a report

Every row carries prefill rate, TTFT and decode rate, as required. When speculative
decoding is on, draft acceptance is reported too, together with K — acceptance rates
are only comparable at equal K.

Two caveats apply to every run recorded here, and they are stated because the numbers
are misleading without them:

- the server this fork ships does **not** emit the per-request `predicted_n` /
  `draft_n_accepted` JSON, so harness-driven tasks report figures weighted over the
  requests that emitted `slot print_timing`, not over the task's true request count;
- the harness reuses its prefix, so a per-request prefill rate on a short prompt is
  launch overhead rather than throughput. The large-prompt requests are where it shows.
