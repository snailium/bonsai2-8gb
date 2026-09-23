# Session logs

Full dsh session logs backing the public claims. Compressed with zstd
(`zstd -dc -- <file>` gives JSONL, one event per line).

| file | config | outcome | backs |
| --- | --- | --- | --- |
| `battery-40k-t3-review.jsonl.zstd` | 40,960 | completed | t3 passes; 31 tool calls, **11 trim elisions** |
| `battery-40k-t4-hostinfo.jsonl.zstd` | 40,960 | completed | t4 passes |
| `battery-40k-t5-research.jsonl.zstd` | 40,960 | completed | t5 passes; **46 tool calls**, 4 elisions |
| `guard-fired-t5-at-40k.jsonl.zstd` | 40,960 | completed | the guard firing at `host:…` ×7 and the pivot after it |
| `fail-32k-t5-low2k.jsonl.zstd` | 32,768 | **max-tokens** | t5 fails at 32K; **guard fired 5×** |
| `fail-32k-t3-timeout.jsonl.zstd` | 32,768 | killed at 1 h | t3 could not finish at 32K |

## Event types you will want

| type | meaning |
| --- | --- |
| `tool/call` | a tool invocation; `data.name`, `data.arguments` (JSON string) |
| `tool/result` | its output; text at `data.message.content[].content[].text` |
| `assistant/message` | model turn; blocks under `data.message.content[]` with `type` = `reasoning` / `text` / `tool-call` |
| **`compaction/prune`** | **a trim span elision** — `{shadowedSeqs, shadowedTokenCount}` |
| `compaction/start` / `compaction/end` | compaction; a failed one carries `data.error` |
| `agent/inbox/spliced` | plugin-injected message; a guard advisory appears here with `source.kind: 'plugin'` |
| `turn/end` | `{reason: {kind}}` — `completed` or `max-tokens` |

## Quick analysis

Both scripts take a *home directory* that contains a `sessions/` tree, and both
accept either zstd-compressed logs (what dsh writes) or plain JSONL (what ships
here). So:

```bash
# unpack one log into a home-shaped directory
mkdir -p /tmp/t5/sessions/s1
zstd -dc -- battery-40k-t5-research.jsonl.zstd > /tmp/t5/sessions/s1/session.jsonl

# then analyse it
../scripts/05-plugin-activity.py /tmp/t5
../scripts/04-extract-metrics.py /tmp/t5 --task t5
```

`05` prints trim elisions, guard advisories (with the fingerprint and count),
compaction health and the turn outcome. `04` prints per-request prefill / TTFT /
decode and a weighted aggregate.

Verified against these logs: `battery-40k-t5-research` gives
**prefill 122.7 tok/s, TTFT 86.9 s, decode 33.77 tok/s** over 46 requests —
the same figures quoted in the write-up.

**A contamination warning** for anyone pointing `04` at a live `DSH_HOME`: every
task run against one home appends its own session directory, so a bare glob
returns the union of every task ever run there. Pass `--session <id>` or a
`--since`/`--until` window. (We were bitten by this; it inflated request counts
until we caught it.) The packed logs here are one-task-per-file, so it does not
arise.
