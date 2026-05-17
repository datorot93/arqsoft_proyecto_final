#!/usr/bin/env bash
# F2 — Bootstrap idempotente de la plataforma de datos y mensajería.
# Asume que F1 ya pasó (cluster + namespaces + NetworkPolicies).
# Documentación: .claude/specs/fase2_plataforma_datos_mensajeria.md

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

say() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }
die() { printf "\033[1;31m✗ ERROR:\033[0m %s\n" "$*" >&2; exit 1; }

# Detección de plataforma: single-node en Mac → Postgres instances=1, Redpanda replicas=1 RF=1
IS_MAC=false
if [ "$(uname -s)" = "Darwin" ]; then
  IS_MAC=true
  warn "macOS single-node: Postgres instances=1, Redpanda replicas=1 RF=1"
fi

# ----- precondición: F1 -----
say "Verificando que F1 esté aplicada"
kubectl get ns linea-verde >/dev/null 2>&1 || die "Namespace 'linea-verde' no existe. Corre 'make up' (F1) primero."
kubectl get ns datos asincrono borde >/dev/null 2>&1 || die "Faltan namespaces de F1. Corre 'make up' primero."
ok "F1 detectada"

# ----- 1. CloudNativePG operator -----
say "Instalando CloudNativePG operator $CNPG_CHART_VERSION"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null
helm upgrade --install cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --version "$CNPG_CHART_VERSION" \
  -f "$ROOT_DIR/infra/helm/cnpg-operator/values.yaml" \
  --wait --timeout 5m
ok "CNPG operator desplegado"

# Esperar webhook + CRDs registrados
kubectl wait --for=condition=Established --timeout=60s crd/clusters.postgresql.cnpg.io
ok "CRDs registrados"

# ----- 2. ConfigMap con SQL de bootstrap -----
say "Aplicando ConfigMap cdt-bootstrap-sql"
kubectl apply -f "$ROOT_DIR/infra/k8s/datos/configmap-bootstrap-sql.yaml"
ok "Bootstrap SQL listo"

# ----- 3. 3 clusters Postgres por país -----
say "Aprovisionando 3 clusters PostgreSQL (pe, mx, co)"
for pais in pe mx co; do
  if $IS_MAC; then
    sed 's/instances: 2/instances: 1/' "$ROOT_DIR/infra/k8s/datos/cluster-$pais.yaml" | kubectl apply -f -
  else
    kubectl apply -f "$ROOT_DIR/infra/k8s/datos/cluster-$pais.yaml"
  fi
done

say "Esperando a que los 3 clusters estén Ready (puede tardar ~3-5 min)"
for pais in pe mx co; do
  echo "    → postgres-$pais"
  kubectl wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres-$pais \
    -n datos --timeout=300s || die "Cluster postgres-$pais no llegó a Ready"
done
ok "3 clusters Postgres healthy"

# ----- 4. NetworkPolicies cross-país -----
say "Aplicando NetworkPolicies cross-país en datos"
kubectl apply -f "$ROOT_DIR/infra/k8s/datos/cross-country-netpol.yaml"
ok "NetworkPolicies cross-país aplicadas"

# ----- 5. Redpanda (MessageBroker) -----
say "Instalando Redpanda $REDPANDA_VERSION"
helm repo add redpanda https://charts.redpanda.com >/dev/null 2>&1 || true
helm repo update redpanda >/dev/null
if $IS_MAC; then
  helm upgrade --install redpanda redpanda/redpanda \
    --namespace asincrono \
    -f "$ROOT_DIR/infra/helm/redpanda/values.yaml" \
    --set statefulset.replicas=1 \
    --set config.cluster.default_topic_replications=1 \
    --set rackAwareness.enabled=false \
    --wait --timeout 5m
else
  helm upgrade --install redpanda redpanda/redpanda \
    --namespace asincrono \
    -f "$ROOT_DIR/infra/helm/redpanda/values.yaml" \
    --wait --timeout 5m
fi
ok "Redpanda desplegado"

# ----- 6. Crear tópicos cdt.eventos y DLQ -----
say "Creando tópicos cdt.eventos (6 part) y cdt.eventos.DLQ"
kubectl delete job redpanda-create-topics -n asincrono --ignore-not-found
if $IS_MAC; then
  # RF=1 en single-node (no hay 3 brokers para RF=3)
  sed 's/--replicas 3/--replicas 1/g' "$ROOT_DIR/infra/k8s/asincrono/topics-job.yaml" | kubectl apply -f -
else
  kubectl apply -f "$ROOT_DIR/infra/k8s/asincrono/topics-job.yaml"
fi
kubectl wait --for=condition=Complete job/redpanda-create-topics -n asincrono --timeout=120s
ok "Tópicos creados"

# ----- 7. Apicurio Schema Registry -----
say "Desplegando Apicurio Registry $APICURIO_REGISTRY_VERSION"
kubectl apply -f "$ROOT_DIR/infra/k8s/asincrono/apicurio.yaml"
kubectl rollout status deployment/apicurio -n asincrono --timeout=180s
ok "Apicurio listo"

# ----- 8. Kong DB-less -----
say "Instalando Kong Gateway $KONG_CHART_VERSION (DB-less)"
helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
helm repo update kong >/dev/null
# Aplicar ConfigMap declarativo ANTES de Helm install (Kong lo monta al arrancar)
kubectl apply -f "$ROOT_DIR/infra/k8s/borde/kong-config.yaml"
helm upgrade --install kong kong/kong \
  --namespace borde \
  --version "$KONG_CHART_VERSION" \
  -f "$ROOT_DIR/infra/helm/kong/values.yaml" \
  --wait --timeout 5m
ok "Kong desplegado"

# ----- 9. resumen -----
say "Resumen de la plataforma F2"
echo
echo "  Postgres clusters:"
kubectl get cluster.postgresql.cnpg.io -n datos -o custom-columns="NAME:.metadata.name,READY:.status.readyInstances,PHASE:.status.phase"
echo
echo "  Redpanda:"
kubectl get pods -n asincrono -l app.kubernetes.io/name=redpanda --no-headers | wc -l | xargs -I{} echo "    brokers: {}"
echo
echo "  Tópicos:"
kubectl exec -n asincrono redpanda-0 -c redpanda -- rpk topic list 2>/dev/null | tail -5
echo
echo "  Apicurio:"
kubectl get deployment apicurio -n asincrono -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
echo
echo "  Kong:"
kubectl get pods -n borde -l app.kubernetes.io/name=kong --no-headers | head -3
echo
echo "════════════════════════════════════════════════════════════════"
ok "Plataforma F2 lista. Ejecuta 'make test-f2' para correr el gate."
echo "════════════════════════════════════════════════════════════════"
