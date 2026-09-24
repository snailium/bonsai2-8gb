# bonsai2-8gb

Prebuilt **llama.cpp binaries for Ternary Bonsai 2 27B** on 8 GB NVIDIA cards,
with working MTP speculative decoding.

**Measured: 54.3 tok/s kernel-only, 65–73 tok/s with MTP, pp512 680** on an RTX 5060 8 GB.
The stock PrismML release binary gives 39.6 tok/s decode and 267 pp512 on the same class of
card — **+37% decode from the kernel**, **+95% prefill** from the MMQ tile work, plus
another **+18–35% from MTP**.

Served at **`-c 40960`** with MTP, which is the largest context this card loads.

Current release: **[v1.1.0](https://github.com/snailium/bonsai2-8gb/releases/tag/v1.1.0)**
(built from `285542d`). v1.0.0 is the older `dcc3be7` build — same decode, half the prefill.

The releases are built from the fork's own branch, which is pinned to a fork commit.
A second branch carrying the **same kernel on top of current upstream mainline** is
published as **[`snailium/bonsai2-mainline`](https://github.com/snailium/bonsai2-mainline)**
(`main`, 120 commits, linear) — **pp512 709.9 (+4.2%), tg128 54.1 (parity)**, same 40K
context and 12 MiB *less* VRAM. Read **[REBASE.md](REBASE.md)** before using it: it
records the method, the six structural defects the merge produced, and the two Metal
and Vulkan gaps that are still open.

| Workload | this build + MTP | acceptance |
| --- | ---: | ---: |
| code | 70.7 tok/s | 0.85 |
| bash | 68.9 tok/s | 0.78 |
| prose | 64.6 tok/s | 0.67 |

---

## What's in here

This repository holds the docs, scripts and evidence. **The binaries live in the
release assets** (they are 147–314 MB, too large for the repo).

```
scripts/serve.sh          serve with the working flags (CTX=40960, low/4096)
scripts/bench.sh          reproduce the kernel benchmark
scripts/make-kv-bias.sh   generate the required KV calibration bias
RECIPE.md                 every flag and why, per-task measurements, 12 caveats
BUILD.md                  rebuild for any GPU, and the three build traps
REBASE.md                 how the fork was replayed onto upstream mainline, and what broke
evidence/                 scripts + raw output + session logs for every claim
```

Download a binary with:
```bash
gh release download --repo snailium/bonsai2-8gb --pattern 'bonsai2-universal.tar.gz'
tar xzf bonsai2-universal.tar.gz && cd bonsai2-universal
```

(The other asset extracts to `bonsai2-5060/` — the directory name matches the
tarball's purpose, not its filename.)

Built from [`sudoingX/llama.cpp`](https://github.com/sudoingX/llama.cpp) branch
**`bonsai2`** at commit **`dcc3be7`** — the PrismML fork plus ten commits:

- **PTQ1_0 mat-vec kernel** ([PR #218](https://github.com/PrismML-Eng/llama.cpp/pull/218),
  468 lines, a new file) — **the +37% decode**. *Still unmerged upstream*, so this is the
  one piece you cannot get without this branch.
- **qwen35 MTP Hadamard fix** ([PR #205](https://github.com/PrismML-Eng/llama.cpp/pull/205),
  merged 2026-09-21) — without it the MTP draft context fails to start. Landing upstream
  already; our branch carries its own copy because `dcc3be7` predates the merge.
- **GATED_DELTA_NET gather fusion**
  ([PR #220](https://github.com/PrismML-Eng/llama.cpp/pull/220)) — *still open upstream*.

**Only #218 and #220 are not upstream.** The MTP fix is already in `prism`; if you build
from a newer commit you get it without patching. See
[BUILD.md](BUILD.md#what-is-actually-in-this-branch) for the full commit list and how this
branch relates to `PrismML-Eng/llama.cpp`.

The paragraph above describes the `dcc3be7` layer (v1.0.0). The `285542d` layer that
v1.1.0 is built from is a different set of ten commits — the PTQ1_0 mat-vec kernel, the
planar-transposed activation layout it consumes, the four-column cap with the shared-memory
budget, and `GGML_CUDA_BATCH_INVARIANT`. Those ten are what
[`snailium/bonsai2-mainline`](https://github.com/snailium/bonsai2-mainline) replays onto
mainline; [REBASE.md](REBASE.md) has the per-file record.

## Quick start

Requires the binary package unpacked first (see [What's in here](#whats-in-here)),
and `scripts/` is relative to that unpacked directory.

```bash
# 1. model weights (5.87 GiB) — from Hugging Face
hf download sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF \
    Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf --local-dir ~/models/bonsai2

# 2. required KV calibration bias (once per model).
#    Writes kv-mean-center.gguf beside the model, which is where serve.sh looks.
./scripts/make-kv-bias.sh ~/models/bonsai2/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf

# 3. serve (defaults: CTX=40960, effort=low, budget=4096)
./scripts/serve.sh
```

Then hit `http://127.0.0.1:18199/v1/chat/completions`.

See **[RECIPE.md](RECIPE.md)** for the full flag list and why each one matters.

---

## Read these before filing a bug

### Which binary

Two release assets — pick the one matching your card:

One asset since v1.1.0: **`bonsai2-universal.tar.gz`** (313 MB) — any CUDA card, Turing
through Blackwell. It embeds native cubins **and** PTX for all eight architectures, so one
binary works everywhere — verified:

```
$ cuobjdump --list-elf bin/libggml-cuda.so.0.21.0
  ... sm_75 sm_80 sm_86 sm_89 sm_90 sm_100 sm_110 sm_120
```

The size difference is entirely `libggml-cuda.so` (68 MB single-arch vs 331 MB
universal) — CUDA kernels are compiled per architecture.

If you build your own and see a load failure or a silent CPU fallback, your
`CMAKE_CUDA_ARCHITECTURES` does not match your card — see [BUILD.md](BUILD.md).

Check yours: `nvidia-smi --query-gpu=compute_cap --format=csv,noheader`

### Which reasoning settings

**Reasoning is not one setting — pick by workload.** Agent/tool-using work wants
`--reasoning-effort low --reasoning-budget 4096`; single-shot document generation wants
`--reasoning off`. The template default (`xhigh`) is actively harmful on this model.
Full reasoning and the measurements behind it: [RECIPE.md](RECIPE.md).

### What actually runs on 8 GB

**At `-c 40960` the whole battery passes — 5/5.** Two generation tasks, a host-inventory
task, a 27-file security review (31 tool calls) and a multi-source research task
(46 tool calls). The same battery at `-c 32768` fails the two heavy ones: the research
task managed 1 pass in 5 attempts (an outlier) and the review could not finish at all.

**The binding constraint is context capacity, not any sampling parameter** — we varied
the reasoning configuration across its full range and it made no difference. Measurements,
the failing runs, and the reasoning: [RECIPE.md](RECIPE.md#battery-results-at-c-40960-55-pass).

**Reproduce any of it:** [evidence/](evidence/) ships the scripts, the raw output for each
claim, and the six full session logs (1.8 MB).

---

## Runtime requirements

- NVIDIA driver (recent enough for your card) — **the CUDA toolkit is not needed**
- CUDA runtime libraries from the system: `libcudart12`, `libcublas12`, `libcublaslt12`,
  `libgomp1`
- **glibc 2.43+** — the binaries are built on Ubuntu 26.04 and carry a `GLIBC_2.43` symbol
  requirement, so Ubuntu 24.04 (glibc 2.39) and older cannot run them. Verify any build with
  `objdump -T bin/libggml-cuda.so.* | grep -o 'GLIBC_2\.[0-9]*' | sort -V | tail -1`.

```bash
sudo apt install libcudart12 libcublas12 libcublaslt12 libgomp1
```

Mind the split: **the binaries are compiled with CUDA 13.1 but link the CUDA 12 runtime ABI**
(`libcudart.so.12`, `libcublas.so.12`, `libcublasLt.so.12`). The system packages above are
therefore the right ones — a CUDA 13 runtime is neither required nor sufficient on its own.

Binaries carry `RUNPATH=$ORIGIN`, so the package is relocatable — move it
anywhere and it still runs (verified).

---

## Credit

- [PrismML](https://prismml.com) — Bonsai 2 and the llama.cpp fork
- [sudoingX](https://github.com/sudoingX/bonsai2-small-gpu) — the PTQ1_0 kernel,
  the MTP graft, and the measurements this build is based on
- Qwen (Alibaba Cloud) — Qwen3.8-27B and the MTP head
- [unsloth](https://huggingface.co/unsloth) — donor GGUF for the MTP graft

Not affiliated with any of them. Weights are Apache 2.0; the binaries are
llama.cpp's MIT.

---

## Measured on

RTX 5060 8 GB (8151 MiB, 447 MiB driver-reserved → 7704 MiB usable), driver
595.91.07, Ubuntu 26.04, kernel 7.0.0-31.

Numbers are reproducible: `scripts/bench.sh` for the kernel figure, and
[`evidence/`](evidence/) for everything else — the scripts, the raw output per claim,
and the session logs behind the agent-task results. Your card will differ; see
`sweeps/` in the kernel repo for other hardware (RTX 3060 12 GB, 3060 Ti 8 GB, 4070).
