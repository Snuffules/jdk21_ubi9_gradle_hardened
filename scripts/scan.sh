#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-ubi9-jdk21-gradle8-hardened:8.14.5}"

if ! command -v trivy >/dev/null 2>&1; then
  echo "trivy not found. Install Trivy or run the GitHub Actions workflow."
  exit 1
fi

trivy image \
  --scanners vuln,secret,misconfig \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --exit-code 1 \
  "${IMAGE}"
