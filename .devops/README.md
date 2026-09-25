# Building and publishing the image

```
cuda.Dockerfile    the image: ubuntu:26.04 + the CUDA 12 runtime + the universal
                   tarball from snailium/bonsai2-mainline, installed by URL and
                   verified against a pinned SHA-256
entrypoint.sh      inside the image: GPU preflight, weights download, KV bias,
                   then exec llama-server (which reads all config from LLAMA_ARG_*)
VERSION            which mainline release the image installs, e.g. b11158-1
build-image.sh     build locally, optionally push
promote-image.sh   move a floating tag onto an existing image, by digest
```

## What triggers a build

`.github/workflows/build.yml` runs on a push to `main` that changes any of:

```
.devops/cuda.Dockerfile
.devops/entrypoint.sh
.devops/VERSION
.dockerignore
.github/workflows/build.yml
```

and on manual `workflow_dispatch`.

Everything else is excluded on purpose:

- **`docker-compose.yml`** configures how the image is *run*; it never enters the
  image, so editing it is not a reason to publish one. Check it locally with
  `docker compose config`.
- **`build-image.sh` / `promote-image.sh`** are local helpers that are not in the
  image either. (This is why the list is written file by file rather than as
  `.devops/**` — a glob would republish on a helper edit.)
- **documentation**, including this file.

`.dockerignore` *is* included: it changes the build context, so leaving it out
would let an image-affecting change ship without a rebuild.

## Tags

| tag | meaning |
| --- | --- |
| `server-dev-<version>-<YYYYMMDD-HHMM>` | immutable candidate, one per build |
| `server-dev` | floating: moved by every successful build |
| `stable` | floating: moved **only** by `promote.yml`, after the image has been run on real hardware |

`<version>` is the upstream identity, e.g. `b11158-1` = llama.cpp `b11158` plus our
revision — not an invented semver.

Test evidence is filed under the dated tag, never under a pointer: `benchmark/` has one
directory per validated build, and its README explains why.

## Promoting

`.github/workflows/promote.yml` is `workflow_dispatch` only. It copies the index
with `buildx imagetools create`, so it re-uploads no layers and cannot rebuild
anything by accident, and it refuses to finish unless the target tag resolves to
the same digest it promoted from.

```
Actions → promote image → Run workflow
  source: sha256:b5245bea…      (or a tag; a digest is safer)
  target: stable
```

Locally: `./promote-image.sh <source> <target>` (see the header for the credential
setup — ~/.docker is not always writable, and GHCR push needs a token with
`write:packages`, which the gh OAuth token does not have).

## Building locally

`./build-image.sh` builds and tags `server-local` plus a dated candidate, and does
not push unless `PUSH=1`. Building needs no GPU; **running** does:

```bash
docker compose -f ../docker-compose.yml up bonsai2-8gb
```

Validate on a real card before promoting: confirm the loaded VRAM at your context,
one correct answer, and a plausible draft-acceptance number.
