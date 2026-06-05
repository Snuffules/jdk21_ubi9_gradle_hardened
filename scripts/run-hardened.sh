#!/usr/bin/env bash
set -euo pipefail

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ubi9-jdk21-gradle8-hardened:8.14.5}"
MOUNT_SUFFIX="${MOUNT_SUFFIX:-:Z}"

if [[ "${ENGINE}" == "docker" ]]; then
  MOUNT_SUFFIX=""
fi

exec "${ENGINE}" run --rm \
  --user 185:0 \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit=512 \
  --memory=4g \
  --cpus=2 \
  --network=none \
  -v "${PWD}:/workspace${MOUNT_SUFFIX}" \
  "${IMAGE}" \
  "$@"
