#!/usr/bin/env bash
# F3 — Bootstrap idempotente del stack de observabilidad.
# Instala kube-prometheus-stack + Tempo + Loki/Promtail + OTel Collector.
# Reactiva monitoring en CNPG, Apicurio y Kong (deshabilitado en F2 por CRDs ausentes).
# Documentación: .claude/specs/fase3_observabilidad.md

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

say()  { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31m✗ ERROR:\033[0m %s\n" "$*" >&2; exit 1; }

# ----- precondición: F1 y F2 -----
say "Verificando que F1 y F2 estén aplicadas"
kubectl get ns observabilidad >/dev/null 2>&1 || die "Namespace 'observabilidad' no existe. Corre 'make up' (F1) primero."
kubectl get ns borde asincrono datos >/dev/null 2>&1 || die "Namespaces de F2 ausentes. Corre 'make platform-up' primero."
ok "F1 y F2 detectadas"

# ----- 1. Repos de Helm -----
say "Registrando repositorios Helm"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community grafana >/dev/null
ok "Repos actualizados"

# ----- 2. kube-prometheus-stack -----
say "Instalando kube-prometheus-stack $KUBE_PROMETHEUS_STACK_VERSION (Prometheus + Grafana + Alertmanager)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace observabilidad \
  --version "$KUBE_PROMETHEUS_STACK_VERSION" \
  -f "$ROOT_DIR/infra/helm/kube-prometheus-stack/values.yaml" \
  --no-hooks \
  --wait --timeout 8m
ok "kube-prometheus-stack desplegado"

# Verificar que las CRDs de monitoring están disponibles
kubectl wait --for=condition=Established --timeout=60s \
  crd/prometheuses.monitoring.coreos.com \
  crd/servicemonitors.monitoring.coreos.com \
  crd/prometheusrules.monitoring.coreos.com \
  crd/podmonitors.monitoring.coreos.com
ok "CRDs de monitoring registradas"

# ----- 3. Grafana Tempo -----
say "Instalando Grafana Tempo $TEMPO_CHART_VERSION"
helm upgrade --install tempo grafana/tempo \
  --namespace observabilidad \
  --version "$TEMPO_CHART_VERSION" \
  -f "$ROOT_DIR/infra/helm/tempo/values.yaml" \
  --wait --timeout 5m
ok "Tempo desplegado"

# ----- 4. Grafana Loki -----
# Bug catch #2 (F3): el Loki 3.x en modo SingleBinary necesita persistence.enabled=true
# porque /var/loki es read-only en la imagen. kind tiene StorageClass "standard" (hostpath).
# Los values.yaml ya reflejan este fix.
say "Instalando Grafana Loki $LOKI_CHART_VERSION (single-binary)"
helm upgrade --install loki grafana/loki \
  --namespace observabilidad \
  --version "$LOKI_CHART_VERSION" \
  -f "$ROOT_DIR/infra/helm/loki/values.yaml" \
  --wait --timeout 5m
ok "Loki desplegado"

# ----- 4b. Promtail (chart separado) -----
# OL9/multi-node kind: Promtail necesita inotify elevados o crashea con "too many open files".
# El script intenta subirlos si tiene sudo; si no, el DaemonSet puede quedar en CrashLoop
# hasta que el operador ejecute manualmente:
#   sudo sysctl -w fs.inotify.max_user_instances=512
#   sudo sysctl -w fs.inotify.max_user_watches=524288
#   echo "fs.inotify.max_user_instances=512"  | sudo tee /etc/sysctl.d/99-inotify.conf
#   echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.d/99-inotify.conf
sudo sysctl -w fs.inotify.max_user_instances=512 2>/dev/null || true
sudo sysctl -w fs.inotify.max_user_watches=524288 2>/dev/null || true

say "Instalando Promtail (chart grafana/promtail)"
helm upgrade --install promtail grafana/promtail \
  --namespace observabilidad \
  --version "$PROMTAIL_CHART_VERSION" \
  --set "config.clients[0].url=http://loki.observabilidad.svc.cluster.local:3100/loki/api/v1/push" \
  --set "serviceMonitor.enabled=true" \
  --set "serviceMonitor.labels.release=kube-prometheus-stack" \
  --wait --timeout 3m \
  && ok "Promtail desplegado" \
  || warn "Promtail no llegó a Ready en 3 min — puede requerir inotify elevados (ver comentario arriba). Continúo."

# ----- 5. Manifiestos K8s de observabilidad -----
say "Aplicando manifiestos de observabilidad"

# ConfigMap de buckets (fuente única — debe existir ANTES de que F4 monte volúmenes)
kubectl apply -f "$ROOT_DIR/infra/k8s/observabilidad/histogram-buckets.yaml"
ok "ConfigMap histogram-buckets aplicado"

# OTel Collector DaemonSet
kubectl apply -f "$ROOT_DIR/infra/k8s/observabilidad/otel-collector.yaml"
ok "OTel Collector DaemonSet aplicado"

# PrometheusRule con las 4 alertas
kubectl apply -f "$ROOT_DIR/infra/k8s/observabilidad/rules/asr-rules.yaml"
ok "PrometheusRule asr-experiment-rules aplicada"

# ServiceMonitors cross-namespace
kubectl apply -f "$ROOT_DIR/infra/k8s/observabilidad/servicemonitors/kong-sm.yaml"
kubectl apply -f "$ROOT_DIR/infra/k8s/observabilidad/servicemonitors/redpanda-sm.yaml"
kubectl apply -f "$ROOT_DIR/infra/k8s/observabilidad/servicemonitors/apicurio-sm.yaml"
ok "ServiceMonitors aplicados (Kong, Redpanda, Apicurio)"

# NetworkPolicies adicionales para scraping cross-namespace
kubectl apply -f "$ROOT_DIR/infra/k8s/observabilidad/netpol-allow-prom-scrape.yaml"
ok "NetworkPolicies de scraping aplicadas"

# ----- 6. Provisioning de dashboards Grafana -----
say "Provisionando 4 dashboards Grafana vía ConfigMap"
kubectl create configmap grafana-dashboards \
  --from-file=golden-signals-red.json="$ROOT_DIR/infra/grafana/dashboards/golden-signals-red.json" \
  --from-file=use-data-broker.json="$ROOT_DIR/infra/grafana/dashboards/use-data-broker.json" \
  --from-file=circuit-breaker.json="$ROOT_DIR/infra/grafana/dashboards/circuit-breaker.json" \
  --from-file=asr-compliance.json="$ROOT_DIR/infra/grafana/dashboards/asr-compliance.json" \
  -n observabilidad \
  --dry-run=client -o yaml | kubectl apply -f -
# Aplicar las labels que el sidecar de Grafana requiere
kubectl label configmap grafana-dashboards grafana_dashboard=1 \
  app.kubernetes.io/part-of=linea-verde-experimento \
  -n observabilidad --overwrite
kubectl annotate configmap grafana-dashboards grafana_folder=LineaVerde \
  -n observabilidad --overwrite
ok "ConfigMap grafana-dashboards aplicado con label grafana_dashboard=1"

# ----- 7. Reactivar monitoring en componentes de F2 -----
# F2 deshabilitó monitoring porque las CRDs no existían.
# Ahora que kube-prometheus-stack está instalado, se reactiva via helm upgrade.
say "Reactivando monitoring en CNPG operator (PodMonitor)"
helm upgrade cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --reuse-values \
  --set monitoring.podMonitorEnabled=true \
  --wait --timeout 3m 2>/dev/null \
  && ok "CNPG monitoring reactivado" \
  || warn "CNPG monitoring upgrade falló — el PodMonitor puede estar ya activo o el chart no lo soporta en esta versión. Continúo."

say "Reactivando ServiceMonitor de Kong"
helm upgrade kong kong/kong \
  --namespace borde \
  --reuse-values \
  --set serviceMonitor.enabled=true \
  --wait --timeout 3m 2>/dev/null \
  && ok "Kong ServiceMonitor reactivado" \
  || warn "Kong ServiceMonitor helm upgrade falló — usando el ServiceMonitor declarativo kong-sm.yaml (ya aplicado). Continúo."

# Apicurio: usa el ServiceMonitor declarativo (infra/k8s/observabilidad/servicemonitors/apicurio-sm.yaml)
# No hay helm chart — el upgrade no aplica. El SM ya fue aplicado en el paso 5.
ok "Apicurio: ServiceMonitor declarativo ya aplicado (no hay chart Helm para upgrade)"

# ----- 8. Esperar a que los pods estén Ready -----
say "Esperando que el stack de observabilidad esté Ready"

echo "    → Prometheus"
kubectl rollout status statefulset -n observabilidad -l app.kubernetes.io/name=prometheus --timeout=180s \
  || warn "Prometheus no llegó a Ready en 3 min — continuando"

echo "    → Grafana"
kubectl rollout status deployment -n observabilidad -l app.kubernetes.io/name=grafana --timeout=180s \
  || warn "Grafana no llegó a Ready en 3 min — continuando"

echo "    → Tempo"
kubectl rollout status deployment -n observabilidad -l app.kubernetes.io/name=tempo --timeout=120s \
  || warn "Tempo no llegó a Ready en 2 min — continuando"

echo "    → Loki"
kubectl rollout status statefulset -n observabilidad -l app.kubernetes.io/name=loki --timeout=120s \
  || warn "Loki no llegó a Ready en 2 min — continuando"

echo "    → OTel Collector DaemonSet"
kubectl rollout status daemonset otel-collector -n observabilidad --timeout=120s \
  || warn "OTel Collector DS no llegó a Ready en 2 min — continuando"

# ----- 9. Resumen -----
say "Resumen del stack de observabilidad F3"
echo
echo "  kube-prometheus-stack:"
kubectl get pods -n observabilidad -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | head -3
echo
echo "  Grafana (NodePort 30300):"
kubectl get pods -n observabilidad -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | head -2
echo
echo "  Tempo:"
kubectl get pods -n observabilidad -l app.kubernetes.io/name=tempo --no-headers 2>/dev/null | head -2
echo
echo "  Loki:"
kubectl get pods -n observabilidad -l app.kubernetes.io/name=loki --no-headers 2>/dev/null | head -2
echo
echo "  OTel Collector (DaemonSet):"
kubectl get ds otel-collector -n observabilidad --no-headers 2>/dev/null
echo
echo "  ServiceMonitors activos:"
kubectl get servicemonitor -n observabilidad --no-headers 2>/dev/null | awk '{print "    ✓ " $1}'
echo
echo "  PrometheusRules:"
kubectl get prometheusrule -n observabilidad --no-headers 2>/dev/null | awk '{print "    ✓ " $1}'

# ----- 10. Instrucción de acceso a Grafana -----
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "127.0.0.1")
echo
echo "════════════════════════════════════════════════════════════════"
ok "Stack de observabilidad F3 listo."
echo
echo "  Acceso a Grafana:"
echo "    URL:      http://${NODE_IP}:30300"
echo "    Usuario:  admin"
echo "    Password: linea-verde-local"
echo
echo "  Alternativa via port-forward:"
echo "    kubectl port-forward -n observabilidad svc/kube-prometheus-stack-grafana 3000:80"
echo "    http://localhost:3000"
echo
echo "  Prometheus:"
echo "    kubectl port-forward -n observabilidad svc/kube-prometheus-stack-prometheus 9090:9090"
echo
echo "  Ejecuta 'make test-f3' para correr el gate de F3."
echo "════════════════════════════════════════════════════════════════"
