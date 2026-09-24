# Bonsai backend on dsh — trial setup (2026-09-23)

Reference for the two-day trial. Everything below is live as of this commit.

## 1. Backend service (dev host .102)

`systemd --user bonsai-serve.service` — **replaced** the previous setup, which ran the
stock PrismML release (`build 10685`, `-c 49152`, thinking off).

| | before | now |
| --- | --- | --- |
| binary | `~/bonsai2/bin` — `7dffb158d` (build 10685, stock) | `~/bonsai2/src/build-new/bin` — **`285542d`** (build 238) |
| context | 49152 | **40960** |
| reasoning | `off` | **`low` + budget 4096** |
| MTP | none | **`draft-mtp --spec-draft-n-max 1`** |
| restart | `no` | **`always`**, 10 s backoff |
| linger | no | **yes** (survives logout/reboot) |

Backups of the old units: `bonsai-serve.service.bak-20260923-134347` (stock release) and
`bonsai-serve.service.bak-before-newbuild-*` (dcc3be7).

### Why 285542d: prefill doubled

Upgrading from `dcc3be7` to `origin/bonsai2 @ 285542d` picked up
[#214](https://github.com/PrismML-Eng/llama.cpp/pull/214), the branch-free MMQ tile loader.
Measured on this card, identical flags, idle GPU:

| | `dcc3be7` | `285542d` | delta |
| --- | ---: | ---: | ---: |
| **pp512** | 349.42 ± 2.94 | **679.88 ± 10.23** | **+94.6%** |
| tg128 | 54.34 ± 0.13 | 54.28 ± 0.13 | unchanged |

**Prefill is 1.95x faster; decode is unchanged**, exactly as #214 states ("the MMVQ path is
untouched"). This matters because every agent turn re-prefills the whole prompt when
context trimming invalidates the cache — the ~72 s/turn we measured should now be ~37 s.

Nine of our ten patches were already in `origin/bonsai2`; only the MTP Hadamard fix
differed, and that landed upstream as #205. So nothing was lost in the move.

```bash
# status / logs / restart
systemctl --user status  bonsai-serve.service
journalctl --user -u bonsai-serve.service -f
systemctl --user restart bonsai-serve.service

# health
curl -s http://127.0.0.1:18080/health
nvidia-smi    # expect ~7600 MiB used
```

Isolation: `bonsai-test.service` was disabled — only one server may hold the GPU.

## 2. dsh provider

`~/.dsh/settings.yaml` (backup: `settings.yaml.bak-before-bonsai-*`):

```yaml
bonsai-8gb:
  apiKeyEnv: B70_API_KEY
  api: openai-completions
  baseURL: http://192.168.111.102:18080/v1
  models:
    - id: /home/gwang/bonsai2/models/mtp-lean.gguf
      name: Bonsai 2 27B · RTX 5060 8GB
      input: [ text ]
      contextWindow: 40960      # MUST match the server's -c
      maxTokens: 8192
      reasoningEfforts: { off: null, low: low }
      compat: { thinkingFormat: qwen-chat-template }
```

The model `id` must be the full path — it is what the server reports on `/v1/models`.

`contextWindow` must equal the server's real `-c`. dsh trusts the declared number; if it
is larger than the backend serves, requests get truncated server-side instead of erroring.

## 3. Compaction: stays local (your choice)

`~/.dsh/.agent-presets/standard-cloud-compact/agent.cordis.yml` covers only `b70-smg` in
its `modelPolicies`, so **`bonsai-8gb` sessions compact on the 5060 itself**.

What that costs, measured: compaction summary requests are ~10K-token prompts, and prefill
on this card runs 124–146 tok/s, so **~30–75 s per compaction**. An agent task at this
context needed **15 compactions** in our t3 run and 6 in t5.

The alternative (what `b70-smg` does) is to route summarization to the cloud:
+28 s instead of 209–372 s on the dual-GPU box. We did **not** add that for Bonsai —
it would send session content to a cloud endpoint, which may not be what you want for a
local model.

To switch later, append to `modelPolicies`:

```yaml
- provider: bonsai-8gb
  model: /home/gwang/bonsai2/models/mtp-lean.gguf
  summarizationProvider: opencode-go-v41
  summarizationModel: deepseek-v4.1-flash
```
(both summarization fields must be set together or it throws)

## 4. Known limits — expect these

| behaviour | why |
| --- | --- |
| ~66–73 tok/s short prompts, **33–45 in agent runs** | decode falls with context depth; agent prompts are 9–15K |
| each agent turn re-prefills the whole prompt (~30–75 s) | context trimming invalidates the prefix cache |
| compaction may fail with *"summary is not smaller than the shadowed content"* | the summarizer cannot shrink what it condenses; at 40,960 this was rare (0 failures), at 32,768 it was common |
| long tool-heavy tasks are slow | 40,960 is the ceiling; beyond it the card cannot load |
| **do not drop MTP to gain context** | 65,536/81,920 load without it, but the model then emits only `/` characters |

## 5. What is running well

Verified after setup:

```
service   active, enabled, linger=yes
context   n_ctx_slot = 40960
MTP       draft context created
VRAM      7606 MiB used / 100 free
request   reasoning + content both stream; 66.4 tok/s
```

## 6. If something looks wrong

```bash
# is it the service or the model?
curl -s http://127.0.0.1:18080/health          # {"status":"ok"}
systemctl --user is-active bonsai-serve.service

# is another process on the GPU?
pgrep -af llama-server                          # should be exactly one
nvidia-smi                                      # ~7.6 GB, one process

# check the trim/guard plugins during a session
python3 /path/to/evidence/scripts/05-plugin-activity.py ~/.dsh/sessions/...
```

The most common failure we hit was **two servers on one GPU** — throughput halves silently
and MTP acceptance drops to ~0 without any error.
