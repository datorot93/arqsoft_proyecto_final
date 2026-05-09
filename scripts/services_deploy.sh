#!/usr/bin/env bash
# F4 — Deploy de los servicios de aplicación en el cluster kind.
#
# Aplica en orden:
#   1. ConfigMaps espejo de histogram-buckets en linea-verde, acl, core-stub.
#   2. Secrets de Postgres copiados desde namespace datos → linea-verde.
#   3. Deployments, Services, HPAs de cdt-pais y outbox-dispatcher en linea-verde.
#   4. Deployment y Service del ACL.
#   5. Deployment y Service de core-stub.
#   6. ServiceMonitors en observabilidad.
#
# Prerrequisitos:
#   - F1, F2, F3 completadas y sus componentes corriendo.
#   - Imágenes ya cargadas (services_build.sh).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$ROOT_DIR/infra/k8s"

echo "=== F4: Deploy de servicios de aplicación ==="

# ================================================================
# 1. ConfigMaps espejo de histogram-buckets
# ================================================================
echo ""
echo "--- 1/6: ConfigMaps espejo de histogram-buckets ---"
kubectl apply -f "$INFRA/observabilidad/histogram-buckets-mirrors.yaml"

# ================================================================
# 2. Copiar secrets de Postgres desde datos → linea-verde
# Limitación K8s: los secrets de CNPG viven en namespace 'datos'.
# Los deployments de cdt-pais y outbox-dispatcher los necesitan en 'linea-verde'.
# ================================================================
echo ""
echo "--- 2/6: Copiando secrets de Postgres a namespace linea-verde ---"
for pais in pe mx co; do
  SECRET_NAME="postgres-${pais}-app"

  # Verificar que el secret existe en datos
  if ! kubectl get secret "$SECRET_NAME" -n datos &>/dev/null; then
    echo "  WARN: Secret $SECRET_NAME no encontrado en namespace datos."
    echo "        Asegúrate de que F2 (CNPG) está corriendo correctamente."
    continue
  fi

  # Copiar a linea-verde (eliminando metadata mutables)
  kubectl get secret "$SECRET_NAME" -n datos -o json \
    | python3 -c "
import json, sys
s = json.load(sys.stdin)
s['metadata'] = {
    'name': s['metadata']['name'],
    'namespace': 'linea-verde',
    'labels': s['metadata'].get('labels', {})
}
s.pop('status', None)
print(json.dumps(s))
" | kubectl apply -f - 2>/dev/null || \
  echo "  INFO: Secret $SECRET_NAME ya existe en linea-verde (apply idempotente)."

  echo "  OK: postgres-${pais}-app → linea-verde"
done

# ================================================================
# 3. Deployments linea-verde (cdt-pais + outbox-dispatcher)
# ================================================================
echo ""
echo "--- 3/6: Deployments en linea-verde ---"
kubectl apply -f "$INFRA/linea-verde/cdt-pais-services.yaml"
kubectl apply -f "$INFRA/linea-verde/cdt-pais-pe-deployment.yaml"
kubectl apply -f "$INFRA/linea-verde/cdt-pais-mx-deployment.yaml"
kubectl apply -f "$INFRA/linea-verde/cdt-pais-co-deployment.yaml"
kubectl apply -f "$INFRA/linea-verde/cdt-pais-hpa.yaml"
kubectl apply -f "$INFRA/linea-verde/outbox-dispatcher-deployments.yaml"

# ================================================================
# 4. ACL
# ================================================================
echo ""
echo "--- 4/6: ACL (namespace acl) ---"
kubectl apply -f "$INFRA/acl/acl-service.yaml"
kubectl apply -f "$INFRA/acl/acl-deployment.yaml"

# ================================================================
# 5. core-stub
# ================================================================
echo ""
echo "--- 5/6: core-stub (namespace core-stub) ---"
kubectl apply -f "$INFRA/core-stub/core-stub-service.yaml"
kubectl apply -f "$INFRA/core-stub/core-stub-deployment.yaml"

# ================================================================
# 6. ServiceMonitors en observabilidad
# ================================================================
echo ""
echo "--- 6/6: ServiceMonitors ---"
kubectl apply -f "$INFRA/observabilidad/servicemonitors/cdt-pais-sm.yaml"
kubectl apply -f "$INFRA/observabilidad/servicemonitors/acl-sm.yaml"
kubectl apply -f "$INFRA/observabilidad/servicemonitors/core-stub-sm.yaml"

# ================================================================
# Esperar rollout
# ================================================================
echo ""
echo "--- Esperando rollout de deployments... ---"
kubectl rollout status deployment/cdt-pais-pe -n linea-verde --timeout=120s || true
kubectl rollout status deployment/cdt-pais-mx -n linea-verde --timeout=120s || true
kubectl rollout status deployment/cdt-pais-co -n linea-verde --timeout=120s || true
kubectl rollout status deployment/acl -n acl --timeout=120s || true
kubectl rollout status deployment/core-stub -n core-stub --timeout=120s || true

echo ""
echo "=== Deploy completado ==="
echo ""
echo "Pods en linea-verde:"
kubectl get pods -n linea-verde -o wide
echo ""
echo "Pods en acl:"
kubectl get pods -n acl -o wide
echo ""
echo "Pods en core-stub:"
kubectl get pods -n core-stub -o wide
echo ""
echo "HPAs:"
kubectl get hpa -n linea-verde
echo ""
echo "Próximo paso: bash scripts/services_smoke.sh"
