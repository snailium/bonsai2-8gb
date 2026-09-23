# The no-MTP collapse

The strongest and most surprising claim in the write-up. Captured by
`scripts/03-no-mtp-collapse.sh`, which runs the controls that rule out the obvious
explanations.

## Observation

Same binary, same card, same prompt (`What is 2+2?`). The only variable is whether
`--spec-type draft-mtp` is present.

| configuration | reasoning | content | slash ratio | verdict |
| --- | ---: | ---: | ---: | --- |
| **32K + MTP** (control) | 47 | 9 | 0.00 | ok — answers "Four" |
| 32K no MTP | 208 | 0 | 1.00 | **COLLAPSE** |
| 32K no MTP (repeat) | 234 | 0 | 1.00 | **COLLAPSE** |
| 64K no MTP | 216 | 0 | 1.00 | **COLLAPSE** |
| 64K no MTP (repeat) | 219 | 0 | 1.00 | **COLLAPSE** |
| 64K no MTP (repeat) | 211 | 0 | 1.00 | **COLLAPSE** |
| no MTP, thinking **off** | 0 | 200 | 1.00 | **COLLAPSE in `content`** |
| no MTP, **original** `PTQ1_0.gguf`, 32K | 206 | 0 | 1.00 | **COLLAPSE** |
| no MTP, **original** `PTQ1_0.gguf`, 64K | 238 | 0 | 1.00 | **COLLAPSE** |

Raw output is literally a run of `/` characters:

```
////////////////////////////////////////////////////////////////////////////////
```

## What the controls rule out

| Explanation | Ruled out by |
| --- | --- |
| "it's the MTP-grafted `-mtp-lean` file" | the **original** `Ternary-Bonsai-2-27B-PTQ1_0.gguf` collapses identically |
| "it's the reasoning path" | with `enable_thinking: false` the collapse appears in `content`, not `reasoning_content` |
| "it's a context-size effect" | 32K and 64K both collapse |
| "it's a sampling problem" | it is deterministic across repeated runs |

## What this does NOT establish

**We report the observation, not the cause.** The symptom — a model emitting one
repeated character — is the classic signature of a mis-computed forward pass rather
than a sampler issue, and the correlation with the draft context is perfect in our
tests. But we did not identify the mechanism and cannot say it will reproduce on
another architecture. We only have one card (sm_120).

## Why it matters practically

The upstream 8 GB guidance is to run **without** the draft head to free VRAM for a
larger context. That is arithmetically sound — our no-MTP measurements match the
documented VRAM figures almost exactly (7,268 MiB vs their 7,266 at `-c 65536`).
But on this build the model stops producing usable output, so **the trade is not
available**: 40,960 with MTP is the real ceiling.

## Reproducing

```bash
./scripts/03-no-mtp-collapse.sh <bin-dir> [lean.gguf] [original.gguf]
```

The probe sends one short prompt and measures the ratio of `/` characters in the
combined output. A ratio above 0.8 is reported as COLLAPSE.
