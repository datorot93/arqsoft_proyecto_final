#!/usr/bin/env bash
# F1 — Bootstrap idempotente del cluster local kind.
# Documentación: .claude/specs/fase1_bootstrap_cluster.md
# Se puede correr N veces sin efectos secundarios.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Cargar versiones pinneadas
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

# ----- helpers -----
say() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }
die() { printf "\033[1;31m✗ ERROR:\033[0m %s\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Falta '$1' (instálalo y reintenta)"; }

# ----- 1. prerrequisitos -----
say "Verificando prerrequisitos"
need docker
need kind
need kubectl
need helm
need jq
ok "Todas las herramientas presentes"

# Verificación de Docker corriendo
docker info >/dev/null 2>&1 || die "Docker no está corriendo (inicia Docker Desktop o el daemon)"
ok "Docker daemon activo"

# Verificación de RAM
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
if [ "$RAM_GB" -lt 14 ]; then
  warn "Solo $RAM_GB GB de RAM disponibles (recomendado >= 14 GB). Continuando..."
else
  ok "RAM disponible: $RAM_GB GB"
fi

# Verificación de puertos críticos
for port in 80 443 6443; do
  if ss -tlnp 2>/dev/null | grep -q ":$port " || lsof -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    die "Puerto $port en uso. Libéralo (otro kind, nginx local, etc.)"
  fi
done
ok "Puertos 80, 443, 6443 libres"

# ----- 2. cluster kind (idempotente) -----
say "Aprovisionando cluster '$KIND_CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  ok "Cluster ya existe; saltando 'kind create'"
else
  kind create cluster \
    --config "$ROOT_DIR/infra/kind/cluster.yaml" \
    --image "$KIND_NODE_IMAGE" \
    --wait 5m
  ok "Cluster creado"
fi

# Establecer contexto explícitamente
kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null
ok "Contexto kubectl: kind-${KIND_CLUSTER_NAME}"

# Esperar nodos Ready
say "Esperando que los 4 nodos queden Ready"
kubectl wait --for=condition=Ready node --all --timeout=180s
ok "4 nodos Ready"

# ----- 3. metrics-server -----
say "Instalando metrics-server (chart $METRICS_SERVER_CHART_VERSION)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --version "$METRICS_SERVER_CHART_VERSION" \
  -f "$ROOT_DIR/infra/helm/metrics-server/values.yaml" \
  --wait --timeout 3m
ok "metrics-server desplegado"

# Verificar que responde (con reintentos — toma ~30s en estabilizar)
say "Verificando metrics-server (puede tardar hasta 60s)"
for i in {1..12}; do
  if kubectl top nodes >/dev/null 2>&1; then
    ok "metrics-server respondiendo"
    break
  fi
  [ "$i" -eq 12 ] && die "metrics-server no responde tras 60s"
  sleep 5
done

# ----- 4. namespaces -----
say "Aplicando los 8 namespaces"
kubectl apply -f "$ROOT_DIR/infra/k8s/00-namespaces.yaml"
ok "Namespaces creados"

# ----- 5. NetworkPolicies -----
say "Aplicando NetworkPolicies (default-deny + allowlist)"
kubectl apply -f "$ROOT_DIR/infra/k8s/01-network-policies/"
ok "NetworkPolicies aplicadas"

# ----- 6. ResourceQuotas + LimitRanges -----
say "Aplicando ResourceQuotas y LimitRanges"
kubectl apply -f "$ROOT_DIR/infra/k8s/02-quotas/"
ok "Quotas y LimitRanges aplicados"

# ----- 7. resumen -----
say "Resumen del cluster"
kubectl get nodes -o wide
echo
kubectl get ns -l app.kubernetes.io/part-of=linea-verde-experimento
echo
echo "════════════════════════════════════════════════════════════════"
ok "Bootstrap F1 completo. Ejecuta 'make test-f1' para correr el gate."
echo "════════════════════════════════════════════════════════════════"
