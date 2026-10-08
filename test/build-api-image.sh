#!/usr/bin/env bash
# Builds the API image from a local te-tengo-general-api checkout (committed content of HEAD) and
# saves it to test/.work/te-tengo-general-api.tar, which the `app` role loads (te_tengo_api_source:
# archive). Uses the checkout's Dockerfile, or test/api.Dockerfile when the checkout has none.
#   TT_API_SRC=/path/to/te-tengo-general-api test/build-api-image.sh
set -euo pipefail
cd "$(dirname "$0")"

SRC="${TT_API_SRC:?TT_API_SRC must point to a te-tengo-general-api checkout}"
IMAGE="${TT_API_IMAGE:-te-tengo-general-api:local}"
WORK=.work
CONTEXT="$WORK/api-src"

git -C "$SRC" rev-parse --verify HEAD >/dev/null
revision=$(git -C "$SRC" rev-parse HEAD)
rm -rf "$CONTEXT" && mkdir -p "$CONTEXT"
git -C "$SRC" archive HEAD | tar -x -C "$CONTEXT"
if [ ! -f "$CONTEXT/Dockerfile" ]; then
  echo "The checkout has no Dockerfile: using test/api.Dockerfile"
  cp api.Dockerfile "$CONTEXT/Dockerfile"
fi

docker build --label "org.opencontainers.image.revision=$revision" --tag "$IMAGE" "$CONTEXT"
docker save --output "$WORK/te-tengo-general-api.tar.partial" "$IMAGE"
if cmp -s "$WORK/te-tengo-general-api.tar.partial" "$WORK/te-tengo-general-api.tar" 2>/dev/null; then
  rm "$WORK/te-tengo-general-api.tar.partial"
else
  mv "$WORK/te-tengo-general-api.tar.partial" "$WORK/te-tengo-general-api.tar"
fi
echo "Saved $IMAGE (te-tengo-general-api ${revision:0:12}) to test/$WORK/te-tengo-general-api.tar"
