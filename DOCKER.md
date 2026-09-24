# Running it with Docker

A walkthrough of the image, start to finish. Every command and every number below
was run on the reference card — an RTX 5060 8 GB with driver 595.91.07.

## What you end up with

One `docker compose up`, then an OpenAI-compatible server on `:18199` running
Ternary Bonsai 2 27B (PTQ1_0) with:

| | |
| --- | --- |
| context | 40960 tokens |
| VRAM | **7496 MiB** of 7704 usable — the 8 GB ceiling, with MTP |
| speed | 65–73 tok/s with MTP; 54 tok/s kernel-only |
| image | `ghcr.io/snailium/bonsai2-8gb/llama-bonsai2:stable`, ~1.8 GB, anonymous pull |

## 0. Prerequisites

Docker and an NVIDIA driver on the host. The container needs the **driver only** —
no CUDA toolkit, and nothing else installed on the host.

```bash
docker --version                 # 29.x tested
docker compose version           # 2.40 tested
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
```

The host also needs **nvidia-container-toolkit**, which is what makes `--gpus all`
work. Ubuntu 26.04 does not ship it, so:

```bash
# NVIDIA's own repository (the key is served as octet-stream, hence the dearmor)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit docker.io docker-compose-v2
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify, and expect your card's name back:

```bash
$ docker run --rm --gpus all ubuntu:26.04 nvidia-smi -L
GPU 0: NVIDIA GeForce RTX 5060 (UUID: GPU-...)
```

If that says `libcuda.so.1: cannot open shared object file` instead, the toolkit is
not wired up — nothing below will work until it is.

## 1. Get the compose file

```bash
git clone https://github.com/snailium/bonsai2-8gb
cd bonsai2-8gb
```

You need `docker-compose.yml`, `.env.example` and `.devops/`. The image contains
everything else.

## 2. Point it at your model directory

```bash
cp .env.example .env
$EDITOR .env
```

Two lines matter. The first is where the 5.85 GiB of weights live:

```
BONSAI2_MODELS_DIR=/home/you/models/bonsai2
```

Use the directory you already keep the model in — a bare-metal
`scripts/serve.sh` reads the same files, and pointing both at one directory is the
whole point of mounting it rather than letting Docker manage a volume.

The second keeps the files yours instead of root's whenever the container has to
download or calibrate something:

```
BONSAI2_UID=1000
BONSAI2_GID=1000
```

> **If your weights are named something other than
> `Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf`**, uncomment `BONSAI2_MODEL` and set
> it to the path *inside* the container, e.g. `/models/mtp-lean.gguf`. Otherwise
> the entrypoint does not find them and downloads a second 6.3 GB copy under the
> canonical name. (This is not hypothetical — it is how we first ran it.)

## 3. Pull

```bash
$ docker pull ghcr.io/snailium/bonsai2-8gb/llama-bonsai2:stable
Digest: sha256:b5245beac224b297faa9e2c6b3299f1c2c289f56d7c69d92f9b2a1067b5a1e7a
Status: Downloaded newer image for ghcr.io/snailium/bonsai2-8gb/llama-bonsai2:stable
```

No login needed. `stable` is moved only after an image has been run on real
hardware; `server-dev` tracks the newest CI build; dated tags such as
`server-dev-b11158-1-20260924-2006` are immutable and are what `stable` is
promoted from.

## 4. Bring it up

```bash
$ docker compose up -d bonsai2-8gb
 Container bonsai2-8gb  Creating
 Container bonsai2-8gb  Created
 Container bonsai2-8gb  Starting
 Container bonsai2-8gb  Started
```

The first start with an empty model directory downloads the weights: 5.85 GiB,
about 80 s on a home connection, verified against the checksum the model repo
publishes:

```
[bonsai2] weights not found at /models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf
[bonsai2] downloading 5.85 GiB from sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF
[bonsai2] weights checksum verified
[bonsai2] installing the calibrated KV bias shipped with this image
[bonsai2] starting llama-server (ctx=40960 kv=q4_0 port=18199)
```

With the weights already in place it skips all of that and is serving in **about
six seconds**.

## 5. Check it

```bash
$ docker compose ps
NAME          IMAGE                                               STATUS
bonsai2-8gb   ghcr.io/snailium/bonsai2-8gb/llama-bonsai2:stable   Up (healthy)

$ docker compose logs | tail -2
bonsai2-8gb  | [bonsai2] starting llama-server (ctx=40960 kv=q4_0 port=18199)
bonsai2-8gb  | srv  llama_server: listening on http://0.0.0.0:18199

$ curl -s http://127.0.0.1:18199/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"m","messages":[{"role":"user","content":"What is 17*23? Number plus one short sentence."}],
         "max_tokens":512,"temperature":0}'
391 It is the product of 17 and 23.

$ nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
7496 MiB, 8151 MiB
```

MTP is doing its job if the logs show a draft acceptance around 0.7–0.85:

```bash
$ docker compose logs | grep acceptance | tail -1
draft acceptance = 0.83333 (  120 accepted /   144 generated), mean len =  1.83
```

## 6. The parameters we ship, and why

Everything is an environment variable in `docker-compose.yml` — no argv — because
llama.cpp maps every server argument to a `LLAMA_ARG_*` variable. The 8 GB profile:

| variable | value | why |
| --- | --- | --- |
| `LLAMA_ARG_CTX_SIZE` | `40960` | the largest context this loads on 8 GB |
| `LLAMA_ARG_CACHE_TYPE_K/V` | `q4_0` | `--kv-mean-center` requires `q4_0` for K |
| `LLAMA_ARG_FLASH_ATTN` | `on` | required by this hybrid architecture |
| `LLAMA_ARG_N_GPU_LAYERS` | `99` | offload everything |
| `LLAMA_ARG_SPEC_TYPE` | `draft-mtp` | the checkpoint's own MTP head |
| `LLAMA_ARG_SPEC_DRAFT_N_MAX` | `1` | verified with one draft token |
| `LLAMA_ARG_REASONING_EFFORT` | `low` | the template default (`xhigh`) is harmful here |
| `LLAMA_ARG_THINK_BUDGET` | `4096` | bounds thinking; note the variable name is *not* `..._REASONING_BUDGET` |
| `LLAMA_ARG_PRESENCE_PENALTY` | `1.5` | anti-loop |

`GGML_CUDA_BATCH_INVARIANT=1` is also set in the image: batch-invariant small-batch
kernels, for reproducible sampling at the batch sizes speculative decoding uses.

The full reasoning, per-task measurements and the caveats are in
[RECIPE.md](RECIPE.md). Raising the context is the one knob to be careful with — do
it a step at a time and watch `nvidia-smi` during load.

## 7. Everyday operations

```bash
docker compose logs -f bonsai2-8gb              # follow
docker compose restart bonsai2-8gb              # restart
docker compose down                             # stop and remove the container
docker compose pull && docker compose up -d     # move to a newer build
```

To pin an exact build instead of following a floating tag, set it in `.env`:

```
BONSAI2_TAG=server-dev-b11158-1-20260924-2006
```

To change any parameter, edit `docker-compose.yml` (or add it to the service's
`environment:`) and `docker compose up -d` again — the weights in the mounted
directory are untouched.

## 8. Troubleshooting

| symptom | cause | fix |
| --- | --- | --- |
| `libcuda.so.1: cannot open shared object file` | container started without the GPU | `docker compose up` (the compose file reserves the device), or `docker run --gpus all`; the entrypoint prints this hint too |
| exits while `initializing the context`, `cudaMalloc failed: out of memory` | the card is not idle — 7496 of 7704 MiB is nearly all of it | close whatever else holds the GPU; consider a smaller `LLAMA_ARG_CTX_SIZE` |
| a second 6.3 GB file appeared in the model directory | the weights were not named `Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf` | set `BONSAI2_MODEL=/models/<your name>.gguf` |
| `unauthorized` when pulling | the package is not visible to you | `docker login ghcr.io -u <user>` with a token that has `read:packages` |
| files in the model directory owned by `root` | the container ran as root | set `BONSAI2_UID`/`BONSAI2_GID` in `.env` |
| first start takes a minute or two | it is downloading 5.85 GiB | expected once; watch `docker compose logs -f` |
| port already in use | something else on 18199 | change the `ports:` mapping |

## 9. What is inside

```
/opt/bonsai2/bin      llama-server, llama-bench, llama-kv-mean-center + shared libs
/opt/bonsai2/scripts  serve.sh, bench.sh, make-kv-bias.sh (the bare-metal equivalents)
/opt/bonsai2/entrypoint.sh
/opt/bonsai2/kv-mean-center.gguf   the calibrated bias
/models               your bind mount: the GGUF, kv-mean-center.gguf, nothing else
```

The entrypoint does exactly three things: check that the driver is visible,
make sure the weights and the KV bias are in `/models`, then `exec llama-server`
with the environment as its configuration. Two things it deliberately does **not**
contain are the weights and the calibration bias, both of which belong on the
volume — a 6.3 GB layer would be re-downloaded on every image update.

Building and publishing images yourself: [.devops/README.md](.devops/README.md).
