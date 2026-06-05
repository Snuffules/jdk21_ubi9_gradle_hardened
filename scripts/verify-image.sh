#!/usr/bin/env bash
set -euo pipefail

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ubi9-jdk21-gradle8-hardened:8.14.5}"

USER_ID="$(${ENGINE} run --rm --entrypoint sh "${IMAGE}" -c 'id -u')"
if [[ "${USER_ID}" == "0" ]]; then
  echo "FAIL: image runs as root"
  exit 1
fi

if [[ "${USER_ID}" != "185" ]]; then
  echo "FAIL: expected UID 185, got ${USER_ID}"
  exit 1
fi

${ENGINE} run --rm --entrypoint sh "${IMAGE}" -c 'java -version'
${ENGINE} run --rm --entrypoint sh "${IMAGE}" -c 'javac -version'
${ENGINE} run --rm "${IMAGE}" --version

${ENGINE} run --rm --entrypoint sh "${IMAGE}" -c 'test ! -f /tmp/gradle.zip'
${ENGINE} run --rm --entrypoint sh "${IMAGE}" -c 'test ! -w /opt/gradle/lib'

${ENGINE} run --rm \
  --user 185:0 \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=512m \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit=128 \
  --memory=1g \
  --cpus=1 \
  --network=none \
  "${IMAGE}" \
  --version

echo "PASS: ${IMAGE} verified"
