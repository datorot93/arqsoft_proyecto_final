#!/usr/bin/env bash
# F3 — Teardown idempotente del stack de observabilidad.
# Deja F1 y F2 intactas.
# Documentación: .claude/specs/fase3_observabilidad.md

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

say()  { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }

say "Eliminando stack de observabilidad F3 (F1 y F2 se mantienen)"

# ----- Manifiestos K8s de observabilidad -----
say "Eliminando recursos K8s de observabilidad"
kubectl delete -f "$ROOT_DIR/infra/k8s/observabilidad/servicemonitors/" --ignore-not-found
kubectl delete -f "$ROOT_DIR/infra/k8s/observabilidad/rules/" --ignore-not-found
kubectl delete -f "$ROOT_DIR/infra/k8s/observabilidad/otel-collector.yaml" --ignore-not-found
kubectl delete -f "$ROOT_DIR/infra/k8s/observabilidad/histogram-buckets.yaml" --ignore-not-found
kubectl delete -f "$ROOT_DIR/infra/k8s/observabilidad/netpol-allow-prom-scrape.yaml" --ignore-not-found
kubectl delete configmap grafana-dashboards -n observabilidad --ignore-not-found
ok "Recursos K8s eliminados"

# ----- Charts Helm de observabilidad -----
say "Eliminando Helm releases de observabilidad"
helm uninstall promtail        -n observabilidad --wait --timeout 3m 2>/dev/null || warn "promtail no instalado"
helm uninstall loki            -n observabilidad --wait --timeout 3m 2>/dev/null || warn "loki no instalado"
helm uninstall tempo           -n observabilidad --wait --timeout 3m 2>/dev/null || warn "tempo no instalado"
helm uninstall kube-prometheus-stack -n observabilidad --wait --timeout 5m 2>/dev/null || warn "kube-prometheus-stack no instalado"
ok "Releases Helm eliminados"

# ----- Revertir monitoring en F2 -----
say "Revirtiendo monitoring en F2 (para que vuelva a arrancar limpio en el próximo platform-up)"
helm upgrade cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --reuse-values \
  --set monitoring.podMonitorEnabled=false \
  --wait --timeout 3m 2>/dev/null \
  && ok "CNPG monitoring desactivado" \
  || warn "No se pudo desactivar monitoring en CNPG (helm release puede no existir)"

helm upgrade kong kong/kong \
  --namespace borde \
  --reuse-values \
  --set serviceMonitor.enabled=false \
  --wait --timeout 3m 2>/dev/null \
  && ok "Kong ServiceMonitor desactivado" \
  || warn "No se pudo desactivar ServiceMonitor en Kong"

# ----- CRDs de monitoring (opcional, no eliminar en kind para no romper F2) -----
# Las CRDs de kube-prometheus-stack se dejan instaladas intencionalmente.
# Eliminarlas requiere kubectl delete crd y puede romper CNPG PodMonitor o Kong SM.
warn "CRDs de monitoring.coreos.com NO se eliminan — se mantienen para re-instalación rápida."

say "Teardown F3 completado. F1 y F2 intactas."
echo "    Para verificar: kubectl get pods -n observabilidad"
