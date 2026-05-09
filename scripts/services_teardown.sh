#!/usr/bin/env bash
# F4 — Teardown de los servicios de aplicación.
# Elimina los deployments F4 sin tocar F1+F2+F3.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$ROOT_DIR/infra/k8s"

echo "=== F4: Teardown de servicios de aplicación ==="
echo "    (F1+F2+F3 no se ven afectados)"

kubectl delete -f "$INFRA/linea-verde/cdt-pais-hpa.yaml" --ignore-not-found
kubectl delete -f "$INFRA/linea-verde/outbox-dispatcher-deployments.yaml" --ignore-not-found
kubectl delete -f "$INFRA/linea-verde/cdt-pais-pe-deployment.yaml" --ignore-not-found
kubectl delete -f "$INFRA/linea-verde/cdt-pais-mx-deployment.yaml" --ignore-not-found
kubectl delete -f "$INFRA/linea-verde/cdt-pais-co-deployment.yaml" --ignore-not-found
kubectl delete -f "$INFRA/linea-verde/cdt-pais-services.yaml" --ignore-not-found
kubectl delete -f "$INFRA/acl/acl-deployment.yaml" --ignore-not-found
kubectl delete -f "$INFRA/acl/acl-service.yaml" --ignore-not-found
kubectl delete -f "$INFRA/core-stub/core-stub-deployment.yaml" --ignore-not-found
kubectl delete -f "$INFRA/core-stub/core-stub-service.yaml" --ignore-not-found
kubectl delete -f "$INFRA/observabilidad/servicemonitors/cdt-pais-sm.yaml" --ignore-not-found
kubectl delete -f "$INFRA/observabilidad/servicemonitors/acl-sm.yaml" --ignore-not-found
kubectl delete -f "$INFRA/observabilidad/servicemonitors/core-stub-sm.yaml" --ignore-not-found

# NO eliminar ConfigMaps espejo ni secrets — son datos
echo ""
echo "=== Teardown F4 completado ==="
