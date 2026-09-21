# Rebuilding for a different GPU

The bundled binaries target **`sm_120` (Blackwell)** only. For Ampere (`sm_86`),
Ada (`sm_89`) or anything else, rebuild — it takes about 10 minutes.

## Why this is not a normal llama.cpp build

Two things differ from upstream:

1. **The source is a fork.** Bonsai 2's ternary `PTQ1_0`/`PQ2_0` types and its
   Hadamard-rotated weight basis are not in mainline llama.cpp. Stock llama.cpp
   rejects these files, or worse, loads a `Q2_0` file and emits gibberish.
2. **The branch carries three unmerged fixes** that matter for performance and
   for MTP:
   - PR #218 — dedicated PTQ1_0 mat-vec kernel (**+37% decode**, no extra VRAM)
   - PR #217 / #205 — qwen35 MTP Hadamard-embedding fix (without it the MTP
     context fails to initialise)
   - PR #220 — GATED_DELTA_NET gather fusion

```
git clone -b bonsai2 https://github.com/sudoingX/llama.cpp
cd llama.cpp && git log --oneline -1   # expect dcc3be7
```

## Two traps nobody documents together

### Trap 1 — CUDA 12.4 cannot target Blackwell

Ubuntu's `nvidia-cuda-toolkit` is CUDA 12.4, which tops out at `compute_90`.
Install a newer toolkit:

```bash
sudo apt install cuda-toolkit-13-1      # provides nvcc at /usr/local/cuda-13.1
/usr/local/cuda-13.1/bin/nvcc --list-gpu-arch | tail   # should list compute_120
```

Set `CMAKE_CUDA_ARCHITECTURES` to your card's compute capability
(`nvidia-smi --query-gpu=compute_cap --format=csv,noheader`).

### Trap 2 — glibc 2.43 breaks nvcc

CUDA's `crt/math_functions.h` declares `rsqrt`/`rsqrtf` without `noexcept`, which
glibc 2.43 requires. nvcc fails with:

```
error: exception specification is incompatible with that of previous function "rsqrt"
```

Fix (from [ggml-org/llama.cpp#19100](https://github.com/ggml-org/llama.cpp/issues/19100)):

```bash
H=/usr/local/cuda-13.1/targets/x86_64-linux/include/crt/math_functions.h
sudo sed -i 's/__func__(double rsqrt(double a));/__func__(double rsqrt(double a) noexcept(true));/' "$H"
sudo sed -i 's/__func__(float rsqrtf(float a));/__func__(float rsqrtf(float a) noexcept(true));/' "$H"
sudo sed -i '629s/rsqrt(double x);/rsqrt(double x) noexcept(true);/' "$H"
sudo sed -i '653s/);/) noexcept(true);/' "$H"
```

The GCC version is irrelevant — the conflict is with glibc, not GCC. We tested
GCC 13, 14 and 15; all fail without the patch.

## Build

```bash
export PATH=/usr/local/cuda-13.1/bin:$PATH
cmake -S llama.cpp -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=120 \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
cmake --build build --config Release -j 10
```

Output lands in `build/bin/`. Copy `llama-server`, `llama-bench`, `llama-cli` and
every `*.so*` into the package's `bin/`.

## Runtime libraries

The binaries link the system CUDA runtime; the toolkit is not needed at run time,
but these are:

```bash
sudo apt install libcudart12 libcublas12 libgomp1
```

## Checking it worked

```bash
cd bin && ./llama-bench --list-devices     # should name your GPU and its compute cap
```

Then reproduce the benchmark:

```bash
scripts/bench.sh    # expect a large jump over the stock PrismML release binary
```
