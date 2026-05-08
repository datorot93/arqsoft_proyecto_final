#!/usr/bin/env bash
# F1 — Teardown del cluster kind. Idempotente.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  echo "==> Eliminando cluster '${KIND_CLUSTER_NAME}'..."
  kind delete cluster --name "$KIND_CLUSTER_NAME"
  echo "✓ Cluster eliminado"
else
  echo "✓ Cluster '${KIND_CLUSTER_NAME}' no existe; nada que hacer"
fi
