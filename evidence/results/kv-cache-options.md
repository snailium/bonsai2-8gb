# KV cache quantization options on this build / card

Measured 2026-09-23 on the RTX 5060 8 GB, at a **fixed `-c 32768`** so VRAM and decode
are comparable across types. Same prompt each time, MTP `n-max 1` on.

## What the server accepts

`llama-server --help` lists nine types for both `-ctk` (K) and `-ctv` (V):

```
f32, f16, bf16, q8_0, q4_0, q4_1, iq4_nl, q5_0, q5_1
```

## What actually runs — measured

| `-ctk` / `-ctv` | loads at 32K? | VRAM | decode | coherent? |
| --- | --- | ---: | ---: | --- |
| **q4_0 / q4_0** | ✅ | **7284 MiB** | **65.95 tok/s** | yes |
| q4_0 / q8_0 | ✅ | 7422 MiB | 58.71 | yes |
| q8_0 / q4_0 | ✅ | 7422 MiB | 59.54 | yes |
| q4_1 / q4_1 | ✅ | 7230 MiB | 62.17 | yes |
| q5_0 / q5_0 | ✅ | 7294 MiB | 53.78 | yes |
| q5_1 / q5_1 | ✅ | 7358 MiB | 53.54 | yes |
| iq4_nl / iq4_nl | ✅ | **7166 MiB** | 48.97 | yes |
| f16 / f16 | ❌ | — | — | — |
| q8_0 / q8_0 | ❌ | — | — | — |

**Both failures are memory, not missing kernels:**

```
f16/f16  : failed to allocate CUDA0 buffer of size 2147483648
           failed to allocate buffer for kv cache
q8_0/q8_0: failed to allocate compute buffers
           failed to allocate compute pp buffers
```

f16 needs a 2 GiB KV buffer at this context; q8_0 fails on the compute side. **They are
not unsupported — they just do not fit 8 GB at 32K.** At a much smaller context they would
load.

## What this says

**`q4_0/q4_0` is the fastest, not merely the smallest.** 65.95 tok/s against 53.78 for
q5_0 and 48.97 for iq4_nl — a ~25% gap, not a rounding difference.

That is worth knowing because the naive expectation is "lower precision is a speed
tradeoff". Here it is the opposite: the q4_0 path is the one the kernels are tuned for on
this fork (it is also the only type `--kv-mean-center` supports). The higher-precision
types give you *less* decode and *no* context gain in practice — q4_1 is smaller than
q5_0 and slower than q4_0, iq4_nl is the smallest of all and the slowest.

**`iq4_nl` saves the most VRAM (7166 vs 7284 MiB → 118 MiB) at a 26% decode cost.** That
118 MiB does not buy a larger context — the ceiling is the compute buffer, not the KV
allocation (we measured 49152 failing on `cudaMalloc` for the compute buffer at q4_0).

## Mixed K/V

`q4_0/q8_0` and `q8_0/q4_0` both work and cost ~7 tok/s versus q4_0/q4_0, for +138 MiB.
The usual reason to use a higher-precision V is output quality on long generations; we did
not measure quality, only that both are coherent on a short prompt.

**`--kv-mean-center` requires `-ctk q4_0`** and is scoped to that type only, per
`docs/kv-mean-center.md`. Choosing any other K type means giving up the mean-centering
bias correction — which is the thing that recovers most of q4_0's accuracy loss on
non-zero-mean channels. That is the main reason to stay on q4_0.

## Bottom line

| if you want… | use |
| --- | --- |
| max speed, max context (current config) | **q4_0 / q4_0** |
| a bit more V precision, can pay ~7 tok/s | q4_0 / q8_0 |
| no reason to switch | — |

**There is no type that gives more context than q4_0 on this card.** The context ceiling
is set by the compute buffer and the 8 GB total, not by how small the KV cache gets —
iq4_nl's 118 MiB saving does not move it.

## Caveats

- One run per type, one short prompt. Decode figures have run-to-run variance of ~±1
  tok/s; the q4_0-vs-q5_0 gap is far larger than that, so it is real.
- "Coherent = yes" means the response contained a plausible Fibonacci function. This is a
  smoke test for garbage output, **not** a quality measurement. We did not run
  perplexity or KLD comparisons.
- Measured at `-c 32768` for comparability. At the golden 40960 every type needs ~1.3 GB
  more, so some of the working types may not fit there — we did not re-run the sweep at
  40960.

## Reproduce

```bash
./scripts/kv-sweep.sh      # from the evidence pack layout
```
