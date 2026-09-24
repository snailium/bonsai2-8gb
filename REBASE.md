# Upstream rebase: carrying the ternary fork onto current llama.cpp mainline

This records how the PrismML ternary fork and our own PTQ1_0 decode kernel were
rebased onto upstream `llama.cpp`, and how the result was verified.

## Why

Three layers sit above upstream:

| Layer | Repository | Role |
| --- | --- | --- |
| mainline | `ggml-org/llama.cpp` | upstream |
| fork | `PrismML-Eng/llama.cpp` (`prism/prism`) | ternary support: PTQ1_0, PQ2_0, Q2_0_g128 |
| ours | `sudoingX/llama.cpp` (`bonsai2`) | PTQ1_0 mat-vec decode kernel, batch-invariant small-batch kernels |

The fork branched at `5ea87ddad` and was 542 commits behind mainline. Staying on
that base means forgoing the upstream prefill work, so the fork had to be
replayed onto mainline HEAD `3423f940`.

## Result

`merge-v3` is **120 commits, linear, on `upstream/master`**:

```
109  PrismML fork commits   (5ea87ddad..prism/prism)
  1  reconcile              (restores mainline content the replay dropped)
 10  our layer              (prism/prism..bonsai2-new)
```

Published as `main` in `snailium/bonsai2-mainline`.

## Mapping back to the original commits

A rebase rewrites every SHA, so each carried-over commit records where it came
from in a trailer:

```
Original-Commit: 01fd9521c92e7882a3fa1083bb933e3bd9305bef
```

119 of the 120 commits carry one — the 109 fork commits and our 10. The
`reconcile` commit is new work and has none.

```bash
# new SHA -> original SHA -> subject, in history order
git log --reverse --topo-order \
  --format='%h  %(trailers:key=Original-Commit,valueonly)  %s' upstream/master..main

# locate the rebased commit that came from a given original
git log --format='%h %s' --grep='Original-Commit: 01fd9521c92e7882a3fa1083bb933e3bd9305bef'

# the original SHAs alone
git log --format='%(trailers:key=Original-Commit,valueonly)' upstream/master..main | grep .
```

The original SHAs do not exist in this repository — a rebase creates new commits.
They identify the pre-rebase commits in `PrismML-Eng/llama.cpp` (the 109) and in
`sudoingX/llama.cpp` branch `bonsai2` (the 10).

### Ordering trap

Positional mapping is only safe under `--topo-order`. Plain `git rev-list` orders
by committer date, and a rebase stamps every replayed commit with essentially the
same committer date, so date order does not follow the parent chain. The naive
mapping produced **26 wrong pairs out of 119** before this was caught;
`--topo-order` gives 0. The trailer pass verifies the mapping independently and
also asserts that the rewritten tip has the byte-identical tree
(`4df9dd5f742755a54d919dd8a6dfda91091be302`), so only messages changed.

## Method

### 1. Choosing the replay strategy

Measured on the real commits before committing to an approach:

| approach | conflict surface |
| --- | --- |
| one merge of the fork tip | 37 files |
| replaying all 109 commits | 166 file-conflict instances |

The 4.5x gap exists because the same files recur across many commits
(`src/models/dflash.cpp` in 5, `common/speculative.cpp` in 6, ...), so the same
conflict is solved repeatedly and the intermediate states cannot be verified.

The chosen route keeps the linear per-commit history a rebase gives, but lets git
do the mechanical part and repairs the tree once:

```
git rebase --onto upstream/master 5ea87ddad -X theirs
```

That completed **109/109 with zero stops**. `-X theirs` resolves every conflict in
favour of the fork, so its cost had to be measured rather than assumed.

### 2. Quantifying what `-X theirs` cost

For every file the fork touched, count fork-added lines that are missing, and
mainline-added lines that are missing:

| direction | result |
| --- | --- |
| fork content present | 99.9% |
| mainline content preserved | 99.6% (479 lines across 32 files missing) |

That turns "the merge is wrong somewhere" into a bounded list.

### 3. Resolving the tree once (the oracle merge)

For each of the 97 files both sides changed, the target content is a real
three-way merge:

```
ours   = upstream/master:file     (mainline is the destination)
base   = 5ea87ddad:file
theirs = prism/prism:file         (the fork feature being carried)
```

computed with `git merge-file -p --diff3`. Regions were resolved mechanically
when:

* one side is unchanged against the base — take the other side
* both sides only add lines — union
* both sides merely reformatted a lookup table — whitespace-insensitive union

That gave 60 clean, 18 auto-resolved and 19 needing judgement. The 19 were
resolved individually.

### 4. The three acceptance gates

Every file had to pass all three. These are why this rebase did not end up like
the earlier attempts.

1. **Content, both directions** — `mainline_missing == 0` and
   `prism_missing == 0`.
2. **Structure** — brace nesting depth, brace balance and preprocessor balance
   must equal one of the two inputs. A merge that silently drops a `}` parses at
   the wrong scope and produces hundreds of compiler errors; a content check
   cannot see this.
3. **No duplication** — no line may appear more often than in either input.

Gate 2 caught a lost `}` in `repack.h` that produced 369 compiler errors.
Gate 3 caught two rounds of duplicate-definition link failures.

## Structural defects found and fixed

| file | defect | fix |
| --- | --- | --- |
| `ggml-cpu/repack.cpp` | 6 byte-identical duplicate `template <>` specialisations and 2 duplicate `tensor_traits` declarations caused link-time multiple definition | removed later copies, only where the whole block is byte-identical |
| `ggml-cpu/arch-fallback.h` | upstream split the x86 kernels into their own translation unit and still aliases the generic Q1_0 symbols on x86; the fork added those kernels and dropped the aliases, so keeping both defines the symbol twice | branch-scoped merge: the x86 branch takes the fork's alias set, every other branch takes mainline's plus the fork-only PQ2_0/PTQ1_0 aliases |
| `ggml-cpu/repack.h` | the union dropped the `}` closing the fork's `if constexpr (K == 2)` arm, so the rest of the header parsed at block scope | took the fork's version (mainline's lines are a strict subset) |
| `ggml-cuda/vecdotq.cuh` | the union nested two mutually exclusive HIP guards inside each other, leaving `qx`/`qy` undeclared on CUDA | took the fork's refactor (`q2_0_symbols4_hip`) |
| `src/llama-model.cpp` | `llama_model_params` is initialised positionally; the union concatenated both sides' lists, producing 26 initialisers for an 18-field struct | restored the struct-ordered 18-entry list |
| `common/speculative.cpp` | did not follow upstream's renames | `dp.n_past` -> `dp.pos0`, and the new `n_max` argument of `common_speculative_impl` |

## The 27% decode regression, and its cause

The first complete build had a serious performance problem:

| build | pp512 | tg128 |
| --- | ---: | ---: |
| production fork `285542d` | 681.3 | **54.29** |
| first merged build | 707.4 | **39.34** |

Ruled out by measurement rather than by reading:

* **KV cache type** — q4_0 / f16 / q8_0 / bf16 all show the same absolute gap
* **CUDA graphs** — disabling them moves both builds by less than 1%
* **`mmvq.cu`** — substituting the fork's copy gave an identical 39.39
* **per-token CUDA kernels** — `gated_delta_net.cu`, `norm.cu`, `fwht.cu`,
  `quantize.cu` and `concat.cu` are all byte-identical to the fork's
* **PTQ1_0 mmvq dispatch** (`ne11 <= 7`) and the recurrent-state type (F32 in all
  three layers)

The cause was a **missing layer**. The replay started from `prism/prism`, so the
10 commits of `sudoingX/bonsai2` were never applied. They contain the decode
work:

* `mmvq-ptq1_0.cuh` (465 lines) — a dedicated PTQ1_0 mat-vec kernel
* the planar-transposed activation layout it consumes
* cap the mat-vec at 4 columns, send 5 and above to the MMQ tile path
* shared-memory budgeting and the `GGML_CUDA_RESTRICT` signature fix
* `GGML_CUDA_BATCH_INVARIANT` for batch-invariant small-batch kernels

Replaying them (`git rebase --onto merge-v2 prism/prism`) restored decode to
parity.

`git cherry` cannot detect this class of error: after a rebase every patch id
changes, so it reports all 109 fork commits as missing whether they are present
or not. The check that works compares each layer separately against the target
branch and counts layer-added lines that are absent.

## Final measurements

Same host, same flags, back to back on an RTX 5060 8 GB:

| | production `285542d` | rebased `merge-v3` |
| --- | ---: | ---: |
| build | ok | ok, 0 errors |
| pp512 | 681.29 | **709.90 (+4.2%)** |
| tg128 | 54.35 | **54.12 (-0.4%)** |
| `-c 40960` + MTP VRAM | 7508 MiB | **7496 MiB** |
| MTP draft acceptance | — | 0.73-0.85 |
| server decode with MTP | — | 66.1 tok/s |

Smoke test: `17*23` answered `391`; "reverse a string" answered `s[::-1]`.

## Known gaps

29 lines (4.6%) of our layer are not on the rebased branch. None of them are on
the CUDA path used here:

| file | lines | why it does not affect this build |
| --- | ---: | --- |
| `ggml-cuda/vecdotq.cuh` | 13 | inside `#if defined(GGML_USE_HIP)` |
| `ggml-sycl/vecdotq.hpp`, `ggml-sycl/ggml-sycl.cpp` | 7, 1 | SYCL, not compiled here |
| `ggml-cuda/gated_delta_net.cu` | 4 | `__CUDA_ARCH__ == GGML_CUDA_CC_DGX_SPARK` (GB10 only) |
| `conversion/base.py` | 2 | model conversion tooling |
| `tests/test-ptq1_0-cuda-dot.cpp` | 1 | host-mirror test for the HIP branch |

(The comparison also flags one line in `src/llama-model.cpp` that is in fact
present; that one is a context difference, not a gap.)

Also outstanding from the fork merge:

* **Vulkan** — PTQ1_0/PQ2_0 are listed in `supports_op` but are not registered in
  the dynamic `pipeline_matmul` map, so that path can assert. Vulkan is neither
  built nor tested here.
* **Metal** — the fork's manual `ssm_conv` fusion and FWHT dispatch threshold were
  superseded by upstream's fusion registry, and `qwen35`'s joint normalisation was
  replaced by upstream's helper (the two are mathematically equivalent).

## Reproducing

```bash
git clone https://github.com/snailium/bonsai2-mainline
cd bonsai2-mainline
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 -DCMAKE_BUILD_TYPE=Release
cmake --build build -j12
```

Then use the flags in `RECIPE.md`.

## Branch layout on the test host

| branch | contents |
| --- | --- |
| `merge-v3` / `merge-v3-verified` | 120 commits, verified; equals `snailium/bonsai2-mainline` `main` |
| `merge-v2` | 110 commits, before our layer was replayed |
| `bonsai2-new` (`285542d`) | the production fork layer, on the old base |
| `merge-backup-*`, `merge-wip` | checkpoints from earlier attempts |
