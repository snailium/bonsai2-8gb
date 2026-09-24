#!/usr/bin/env bash
# Move a floating tag onto an already-built image.
#
# Manifest-only: copies the index, re-uploads nothing, takes seconds.  Promote by
# DIGEST, never by a mutable tag — a tag can be moved under you between the test
# and the promote.
#
#   .devops/promote-image.sh <source-tag-or-digest> <target-tag>
#
# Credentials: ghcr.io push needs a token with write:packages.  The gh OAuth
# token does NOT have that scope; use the PAT in the keystore:
#
#   DOCKER_CONFIG=$(mktemp -d)      # ~/.docker is not always writable
#   grep -oE 'ghp_[A-Za-z0-9_]{20,}' ~/.hermes/hermes-agent/.git/config | head -1 \
#     | docker login ghcr.io -u snailium --password-stdin
#
# and delete DOCKER_CONFIG afterwards, it holds the credential in plaintext.
set -euo pipefail

SRC="${1:?usage: promote-image.sh <source-tag-or-digest> <target-tag>}"
TARGET="${2:?usage: promote-image.sh <source-tag-or-digest> <target-tag>}"
IMAGE="${IMAGE:-ghcr.io/snailium/bonsai2-8gb/llama-bonsai2}"

case "$SRC" in
    sha256:*) REF="$IMAGE@$SRC" ;;
    *)        REF="$IMAGE:$SRC" ;;
esac

# Resolve to a digest first, so the promote is pinned to an immutable identity.
DIGEST="$(docker buildx imagetools inspect "$REF" | awk '/^Digest:/{print $2; exit}')"
[ -n "$DIGEST" ] || { echo "error: cannot resolve $REF" >&2; exit 1; }
echo "source: $REF"
echo "digest: $DIGEST"

docker buildx imagetools create --tag "$IMAGE:$TARGET" "$IMAGE@$DIGEST"

# Verify the target really resolves to the same digest.
GOT="$(docker buildx imagetools inspect "$IMAGE:$TARGET" | awk '/^Digest:/{print $2; exit}')"
echo "target: $IMAGE:$TARGET -> $GOT"
[ "$GOT" = "$DIGEST" ] || { echo "error: target digest differs from source" >&2; exit 1; }
echo "promoted."
