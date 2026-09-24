# syntax=docker/dockerfile:1
#
# Universal CUDA runtime image for Ternary Bonsai 2 27B.
#
# Design notes
# ------------
# * The image does NOT compile llama.cpp.  It installs the prebuilt universal
#   tarball published by snailium/bonsai2-mainline and verifies its SHA-256, so the
#   binaries inside the image are byte-for-byte the ones that were benchmarked.
#   One built-binary lineage, and the image stays a thin auditable wrapper.
# * One image, every CUDA card.  The tarball carries native cubins AND PTX for
#   sm_75..sm_120, so nothing here is specific to an 8 GB card; the per-VRAM tuning
#   lives in docker-compose.yml as one service per memory class.
# * Base is ubuntu:26.04 because the binaries carry a GLIBC_2.43 requirement.
#   24.04 (glibc 2.39) cannot run them.  The base provides the CUDA 12 runtime
#   packages the binaries link; the CUDA *toolkit* is not needed at run time.
# * No model weights. 5.85 GiB belongs on a mounted volume, not in a layer.
#
# The caller/operator is responsible for using this image in line with the model
# and drivers' licences and the target site's rules.

ARG UBUNTU_VERSION=26.04
FROM ubuntu:${UBUNTU_VERSION}

# Re-declared after FROM: an ARG set before FROM is only in scope for FROM itself,
# so the LABEL below would otherwise interpolate an empty string.
ARG UBUNTU_VERSION

ARG BONSAI2_VERSION=b11158-1
ARG TARBALL=bonsai2-cuda-universal-${BONSAI2_VERSION}.tar.gz
ARG TARBALL_URL=https://github.com/snailium/bonsai2-mainline/releases/download/${BONSAI2_VERSION}/${TARBALL}
# Pinned so a re-tagged or tampered release cannot silently change the image.
ARG TARBALL_SHA256=652cd2b012c17a353c76ca8185ea1a28edfc47d38be799ab356fc91396f33b48

LABEL org.opencontainers.image.title="llama-bonsai2" \
      org.opencontainers.image.description="Ternary Bonsai 2 27B (PTQ1_0) runtime, universal CUDA build" \
      org.opencontainers.image.source="https://github.com/snailium/bonsai2-mainline" \
      org.opencontainers.image.version="${BONSAI2_VERSION}" \
      org.opencontainers.image.base.name="ubuntu:${UBUNTU_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      io.snailium.llama.cpp.base-tag="b11158" \
      io.snailium.llama.cpp.base-commit="3423f940" \
      io.snailium.backend="cuda" \
      io.snailium.cuda.arches="75 80 86 89 90 100 110 120" \
      io.snailium.cuda.runtime="12" \
      io.snailium.glibc.floor="2.43"

# libcudart12 / libcublas12 / libgomp1 are the three runtime dependencies;
# libcublasLt.so.12 arrives transitively through libcublas.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libcudart12 libcublas12 libgomp1 \
        ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/bonsai2
RUN set -eux; \
    curl -fsSL --retry 3 -o "/tmp/${TARBALL}" "${TARBALL_URL}"; \
    echo "${TARBALL_SHA256}  /tmp/${TARBALL}" | sha256sum -c -; \
    tar xzf "/tmp/${TARBALL}" -C /opt/bonsai2 --strip-components=1; \
    rm -f "/tmp/${TARBALL}"; \
    test -x /opt/bonsai2/bin/llama-server

COPY .devops/entrypoint.sh /opt/bonsai2/entrypoint.sh
RUN chmod 0755 /opt/bonsai2/entrypoint.sh

ENV LD_LIBRARY_PATH=/opt/bonsai2/bin

# Batch-invariant small-batch kernels.  Needed for reproducible sampling at the
# 1-4 column batch sizes speculative decoding uses.
ENV GGML_CUDA_BATCH_INVARIANT=1

# Tuned defaults, all overridable from docker-compose.yml or `docker run -e`.
# llama.cpp maps every server argument to an LLAMA_ARG_* variable, so the whole
# configuration is environment and no argv is used.
ENV LLAMA_ARG_HOST=0.0.0.0 \
    LLAMA_ARG_PORT=18199 \
    LLAMA_ARG_N_GPU_LAYERS=99 \
    LLAMA_ARG_FLASH_ATTN=on \
    LLAMA_ARG_N_PARALLEL=1 \
    LLAMA_ARG_CACHE_TYPE_K=q4_0 \
    LLAMA_ARG_CACHE_TYPE_V=q4_0 \
    LLAMA_ARG_JINJA=1 \
    LLAMA_ARG_REASONING_EFFORT=low \
    LLAMA_ARG_THINK_BUDGET=4096 \
    LLAMA_ARG_SPEC_TYPE=draft-mtp \
    LLAMA_ARG_SPEC_DRAFT_N_MAX=1 \
    LLAMA_ARG_TEMPERATURE=0.7 \
    LLAMA_ARG_TOP_K=20 \
    LLAMA_ARG_TOP_P=0.80 \
    LLAMA_ARG_MIN_P=0.0 \
    LLAMA_ARG_PRESENCE_PENALTY=1.5 \
    LLAMA_ARG_FREQUENCY_PENALTY=0.0 \
    LLAMA_ARG_REPEAT_PENALTY=1.0

# 40960 is the largest context this loads on an 8 GB card; -fa plus q4_0 KV keep
# it inside 7.6 GiB with MTP.  Larger cards can raise it in their service.
ENV LLAMA_ARG_CTX_SIZE=40960

# Weights and the calibration bias live on a volume, never in a layer.
ENV BONSAI2_MODEL_DIR=/models \
    BONSAI2_MODEL=/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf \
    BONSAI2_KV_BIAS=/models/kv-mean-center.gguf \
    BONSAI2_HF_REPO=sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF \
    BONSAI2_AUTODOWNLOAD=1

VOLUME ["/models"]
EXPOSE 18199

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=5 \
    CMD curl -fsS "http://127.0.0.1:${LLAMA_ARG_PORT}/health" || exit 1

ENTRYPOINT ["/opt/bonsai2/entrypoint.sh"]
