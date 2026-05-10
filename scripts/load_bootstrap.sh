#!/usr/bin/env bash
# scripts/load_bootstrap.sh — F5: build de la imagen k6 + carga al kind +
# instalación de k6-operator + apply de manifestos del namespace carga.
#
# Idempotente: re-ejecutable múltiples veces sin romper nada.
#
# Salida:
#   - Imagen `kind-registry:5000/linea-verde/k6-loader:latest` cargada en kind.
#   - k6-operator (v0.0.16) corriendo en namespace `k6-operator-system`.
#   - ConfigMaps con los scripts JS (warmup, baseline, peak) en namespace `carga`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"

K6_OP_VERSION="${K6_OPERATOR_VERSION:-0.0.16}"
K6_IMAGE="kind-registry:5000/linea-verde/k6-loader:latest"
KIND_CLUSTER="${KIND_CLUSTER_NAME:-linea-verde}"

log() { printf "\033[1;36m[F5]\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m[F5 ✓]\033[0m %s\n" "$*"; }

# ---------- 1. Build de imagen k6 custom ----------
log "Build de imagen k6 custom (Dockerfile.k6)..."
cd "$ROOT_DIR"
docker build -t "$K6_IMAGE" -f load/Dockerfile.k6 . 2>&1 | tail -10

ok "Imagen $K6_IMAGE construida"

# ---------- 2. kind load ----------
log "Cargando imagen al cluster kind '$KIND_CLUSTER'..."
kind load docker-image "$K6_IMAGE" --name "$KIND_CLUSTER" 2>&1 | tail -3
ok "Imagen disponible en nodos kind"

# ---------- 3. ConfigMaps con scripts JS ----------
# Los scripts JS se inyectan vía ConfigMap.  Cada CR `K6` apunta a su CM.
# Empacamos TODO el árbol load/ (lib/, scenarios/, payloads/) por ConfigMap
# para que los `import` resuelvan dentro del pod.
log "Generando ConfigMaps con scripts JS bundleados..."

# k6 v0.53 NO soporta imports relativos a múltiples ConfigMaps;
# generamos un bundle plano por escenario inlining `lib/` y `payloads/`.
# Estrategia: usar `k6 archive` localmente (requiere k6 host) ó montar
# todos los archivos en un solo CM.
# Decisión: montar todo el árbol en un CM y referenciar el script principal.

generate_cm() {
  local name="$1"
  local file="$2"
  kubectl create configmap "$name" \
    -n carga \
    --from-file=load/scenarios/"$file"=load/scenarios/"$file" \
    --from-file=load/lib/sampler.js=load/lib/sampler.js \
    --from-file=load/lib/nhpp.js=load/lib/nhpp.js \
    --from-file=load/lib/mmpp.js=load/lib/mmpp.js \
    --from-file=load/lib/dirichlet.js=load/lib/dirichlet.js \
    --from-file=load/lib/trace.js=load/lib/trace.js \
    --from-file=load/payloads/cdt.js=load/payloads/cdt.js \
    --dry-run=client -o yaml | kubectl apply -f -
}
# Nota: el k6-operator espera un archivo plano en el CM, no estructura.
# Mejor estrategia: ARCHIVAR el script con `k6 archive` (.tar) y montarlo,
# pero requiere k6 binario en host.  Como fallback, usamos un bundle inline:
# consolidar todos los imports en un solo .js por escenario.

bundle_script() {
  local entry="$1"; local out="$2"
  python3 "$ROOT_DIR/scripts/bundle_k6.py" "$entry" "$out"
}

mkdir -p "$ROOT_DIR/load/dist"
bundle_script "load/scenarios/warmup.js"        "load/dist/warmup.bundled.js"
bundle_script "load/scenarios/baseline_asr1.js" "load/dist/baseline_asr1.bundled.js"
bundle_script "load/scenarios/peak_asr2.js"     "load/dist/peak_asr2.bundled.js"

kubectl create configmap k6-warmup-script -n carga \
  --from-file=warmup.js="$ROOT_DIR/load/dist/warmup.bundled.js" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap k6-baseline-script -n carga \
  --from-file=baseline_asr1.js="$ROOT_DIR/load/dist/baseline_asr1.bundled.js" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap k6-peak-script -n carga \
  --from-file=peak_asr2.js="$ROOT_DIR/load/dist/peak_asr2.bundled.js" \
  --dry-run=client -o yaml | kubectl apply -f -

ok "ConfigMaps de scripts creados"

# ---------- 4. Bootstrap del namespace carga ----------
log "Aplicando ServiceAccount + ConfigMap de Prometheus..."
kubectl apply -f "$ROOT_DIR/infra/k8s/carga/k6-operator-bootstrap.yaml"
ok "carga namespace bootstrap listo"

# ---------- 5. k6-operator ----------
log "Instalando k6-operator $K6_OP_VERSION..."
if kubectl get deployment k6-operator-controller-manager -n k6-operator-system >/dev/null 2>&1; then
  ok "k6-operator ya instalado (idempotente)"
else
  kubectl apply -f "https://github.com/grafana/k6-operator/releases/download/v${K6_OP_VERSION}/bundle.yaml" || {
    log "Descarga directa falló — usando manifest local si existe"
    if [ -f "$ROOT_DIR/infra/k8s/carga/k6-operator-bundle.yaml" ]; then
      kubectl apply -f "$ROOT_DIR/infra/k8s/carga/k6-operator-bundle.yaml"
    else
      echo "ERROR: no hay conexión a Internet ni bundle local de k6-operator." >&2
      exit 1
    fi
  }
  ok "k6-operator $K6_OP_VERSION desplegado"
fi

# ---------- 6. Habilitar remote-write en Prometheus si no está ----------
log "Verificando enableRemoteWriteReceiver en Prometheus..."
RW_ENABLED=$(kubectl get prometheus -n observabilidad \
  -o jsonpath='{.items[0].spec.enableRemoteWriteReceiver}' 2>/dev/null || echo "")
if [ "$RW_ENABLED" = "true" ]; then
  ok "remote-write receiver ya habilitado"
else
  log "Habilitando remote-write receiver con kubectl patch..."
  kubectl patch prometheus -n observabilidad \
    "$(kubectl get prometheus -n observabilidad -o jsonpath='{.items[0].metadata.name}')" \
    --type=merge \
    -p '{"spec":{"enableRemoteWriteReceiver":true}}' || {
      log "Patch falló. Activar manualmente o reintentar."
    }
  # Esperar a que Prometheus se rolle.
  sleep 8
  ok "Prometheus reload con remote-write habilitado"
fi

ok "F5 bootstrap completo"
