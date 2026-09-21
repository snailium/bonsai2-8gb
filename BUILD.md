# Rebuilding for a different GPU

The bundled binaries come in two flavours — pick by your card:

| Asset | Architectures |
| --- | --- |
| `bonsai2-universal.tar.gz` | sm_75, 80, 86, 89, 90, 100, 110, 120 (+ PTX) — **everything** |
| `bonsai2-5060.tar.gz` | sm_120 only |

If neither suits you, or you want a smaller build, rebuild — ~10 minutes, and
only `CMAKE_CUDA_ARCHITECTURES` changes.

**How to tell which you have:**

```bash
nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader
```

| Card | Compute capability | `-DCMAKE_CUDA_ARCHITECTURES=` |
| --- | --- | --- |
| RTX 2080 / 2070 (Turing) | 7.5 | 75 |
| RTX 3080 / 3090 (Ampere) | 8.6 | **86** |
| RTX 4070 / 4090 (Ada) | 8.9 | **89** |
| RTX 5060 / 5070 / 5090 (Blackwell) | 12.0 | 120 |

A binary built for one architecture will not run on another — CUDA 13 supports
all of them, but the compiled cubins are architecture-specific. Confirm what a
binary contains with `cuobjdump --list-elf <path>/libggml-cuda.so`.

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

## Three traps nobody documents together

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

### Trap 3 — CMake silently picks the wrong nvcc

If you installed CUDA 13.1 alongside an older toolkit, `cmake` may still find the
**older** nvcc via `PATH` and fail with:

```
ptxas fatal : Value 'sm_52' is not defined for option 'gpu-name'
```

`sm_52` is a CUDA 12-era default. Passing `CUDAARCHS` does **not** help, because
the failure happens during CMake's compiler *identification* probe, before
architecture selection. Name the compiler explicitly instead:

```
-DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.1/bin/nvcc
```

If anything looks odd, check which nvcc CMake found in
`build/CMakeCache.txt` (`CMAKE_CUDA_COMPILER`).

## Build

```bash
cmake -S llama.cpp -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.1/bin/nvcc \
  -DCMAKE_CUDA_ARCHITECTURES=86 \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
cmake --build build --config Release -j 10
```

**Every CUDA card in one binary** (slower build, larger output — this is what
`bonsai2-universal.tar.gz` was built from):

```bash
cmake -S llama.cpp -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.1/bin/nvcc \
  "-DCMAKE_CUDA_ARCHITECTURES=75-real;80-real;86-real;89-real;90-real;100-real;110-real;120-real;75-virtual;80-virtual;86-virtual;89-virtual;90-virtual;100-virtual;110-virtual;120-virtual" \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
cmake --build build --config Release -j 10
```

`-real` entries emit native cubins; `-virtual` entries emit PTX that the driver
JIT-compiles for architectures newer than the toolkit knows. Include the
`-virtual` set for forward compatibility```

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
