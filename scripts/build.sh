#!/usr/bin/env bash
set -euo pipefail

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ubi9-jdk21-gradle8-hardened}"
GRADLE_VERSION="${GRADLE_VERSION:-8.14.5}"
GRADLE_SHA256="${GRADLE_SHA256:-6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854}"
TAG="${TAG:-${IMAGE}:${GRADLE_VERSION}}"

exec "${ENGINE}" build \
  --pull=always \
  --build-arg "GRADLE_VERSION=${GRADLE_VERSION}" \
  --build-arg "GRADLE_SHA256=${GRADLE_SHA256}" \
  -t "${TAG}" \
  -f Dockerfile .
