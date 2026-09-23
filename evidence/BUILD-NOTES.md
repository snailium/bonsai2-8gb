# Build notes — three traps you will hit

The binary used for every measurement here is from
`sudoingX/llama.cpp` branch **`bonsai2` @ `dcc3be7`**, built for **sm_120**.

The upstream prebuilt tarball is **Ampere/Ada only** and cannot be used on a 5060.
You must build from source, and these three things will stop you.

## Trap 1 — CUDA 12.4 cannot target Blackwell

Ubuntu's `nvidia-cuda-toolkit` is CUDA 12.4, which tops out at `compute_90`.
It has no idea what `sm_120` is. You need a newer toolkit:

```bash
sudo apt install cuda-toolkit-13-1
/usr/local/cuda-13.1/bin/nvcc --list-gpu-arch | tail   # should list compute_120
```

Check your card's compute capability:
```bash
nvidia-smi --query-gpu=compute_cap --format=csv,noheader    # 12.0 for a 5060
```

## Trap 2 — glibc 2.43 breaks nvcc

CUDA's `crt/math_functions.h` declares `rsqrt`/`rsqrtf` without `noexcept`, which
glibc 2.43 now requires. nvcc fails with:

```
error: exception specification is incompatible with that of previous function "rsqrt"
```

Fix (from [ggml-org/llama.cpp#19100](https://github.com/ggml-org/llama.cpp/issues/19100)):

```bash
H=/usr/local/cuda-13.1/targets/x86_64-linux/include/crt/math_functions.h
sudo cp "$H" "$H.bak"
sudo sed -i 's/__func__(double rsqrt(double a));/__func__(double rsqrt(double a) noexcept(true));/' "$H"
sudo sed -i 's/__func__(float rsqrtf(float a));/__func__(float rsqrtf(float a) noexcept(true));/' "$H"
sudo sed -i '629s/rsqrt(double x);/rsqrt(double x) noexcept(true);/' "$H"
sudo sed -i '653s/);/) noexcept(true);/' "$H"
```

**The GCC version is irrelevant** — we tested GCC 13, 14 and 15; all fail without
the patch. The conflict is with glibc, not GCC.

## Trap 3 — cmake silently picks the wrong nvcc

If you installed CUDA 13.1 alongside an older toolkit, cmake may still find the
**old** nvcc via `PATH` and fail with:

```
ptxas fatal : Value 'sm_52' is not defined for option 'gpu-name'
```

`sm_52` is a CUDA 12-era default. **Setting `CUDAARCHS` does not help**, because the
failure happens during cmake's compiler *identification* probe, before architecture
selection. Name the compiler explicitly:

```
-DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.1/bin/nvcc
```

## The build

```bash
git clone -b bonsai2 https://github.com/sudoingX/llama.cpp
cd llama.cpp && git log --oneline -1      # expect dcc3be7

export PATH=/usr/local/cuda-13.1/bin:$PATH
cmake -S . -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.1/bin/nvcc \
  -DCMAKE_CUDA_ARCHITECTURES=120 \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
cmake --build build --config Release -j 10
```

**A multi-architecture build** (one binary for every CUDA card) — this is what our
published release contains:

```
"-DCMAKE_CUDA_ARCHITECTURES=75-real;80-real;86-real;89-real;90-real;100-real;110-real;120-real;\
75-virtual;80-virtual;86-virtual;89-virtual;90-virtual;100-virtual;110-virtual;120-virtual"
```

`-real` emits native cubins, `-virtual` emits PTX the driver can JIT forward.

## Runtime libraries

The binaries link the system CUDA runtime; the toolkit is not needed at run time,
but these are:

```bash
sudo apt install libcudart12 libcublas12 libgomp1
```

## Sanity check

```bash
bin/llama-bench --list-devices
# should name your GPU and its compute capability
```

Then reproduce the benchmark with `scripts/01-bench-tg128.sh`.

## One packaging trap worth knowing

If you redistribute the binaries: **do not `strip` them.** `strip --strip-unneeded`
on the llama.cpp shared objects produces a **segfault** on the next run. We found
this the hard way building the release tarball. Copy `.so` chains with `cp -P` too,
or symlink chains get dereferenced into three full copies.
