#!/usr/bin/env bash
# Build the CUDA image locally.
#
# Building does NOT need a GPU — only running does.  Build here (PC-DEV has
# buildx), push to GHCR, then pull and run it on the GPU host to validate.
#
#   .devops/build-image.sh [tag-suffix]
#
# By default the image is tagged locally only, so a build cannot publish by
# accident; pass PUSH=1 to push the dated candidate and the floating dev tag.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$DIR/.devops/VERSION")"
STAMP="$(date -u +%Y%m%d-%H%M)"
IMAGE="${IMAGE:-ghcr.io/snailium/bonsai2-8gb/llama-bonsai2}"
SUFFIX="${1:-}"

CANDIDATE="server-dev-${VERSION}-${STAMP}${SUFFIX:+$SUFFIX}"
echo "version   : $VERSION"
echo "candidate : $IMAGE:$CANDIDATE"

docker build \
    -f "$DIR/.devops/cuda.Dockerfile" \
    --build-arg "BONSAI2_VERSION=$VERSION" \
    -t "$IMAGE:server-local" \
    -t "$IMAGE:$CANDIDATE" \
    "$DIR"

if [ "${PUSH:-0}" = "1" ]; then
    echo "pushing $IMAGE:$CANDIDATE and $IMAGE:server-dev"
    docker push "$IMAGE:$CANDIDATE"
    docker push "$IMAGE:server-dev"   # only works if it already points here; use promote for that
else
    echo
    echo "built locally.  to publish:"
    echo "  docker push $IMAGE:$CANDIDATE"
    echo "  .devops/promote-image.sh $CANDIDATE server-dev"
fi
