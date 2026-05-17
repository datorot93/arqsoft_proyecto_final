#!/usr/bin/env bash
# F1 — Pruebas de salida (gate hacia F2).
# Implementa los 9 tests de .claude/specs/fase1_bootstrap_cluster.md
# Si cualquier prueba BLOQUEANTE falla, exit code != 0 y no se promueve a F2.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

PASS=0
FAIL_BLOCK=0
FAIL_INFO=0
TOTAL=0

# ----- helpers -----
section() {
  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "$*"
  echo "════════════════════════════════════════════════════════════════"
}

run_test() {
  # $1=ID  $2=desc  $3=cmd  $4=expected_regex  $5=gate(BLOQUEANTE|INFORMATIVO)
  local id="$1" desc="$2" cmd="$3" expected="$4" gate="$5"
  TOTAL=$((TOTAL + 1))
  printf "\n[%s · %s] %s\n  $ %s\n" "$id" "$gate" "$desc" "$cmd"
  local actual
  actual=$(bash -c "$cmd" 2>&1 || true)
  if echo "$actual" | grep -qE "$expected"; then
    printf "  \033[1;32m✓ PASS\033[0m  (match: %s)\n" "$expected"
    PASS=$((PASS + 1))
    return 0
  else
    printf "  \033[1;31m✗ FAIL\033[0m  esperado regex: %s\n" "$expected"
    printf "         obtenido:\n"
    echo "$actual" | sed 's/^/           /' | head -5
    if [ "$gate" = "BLOQUEANTE" ]; then
      FAIL_BLOCK=$((FAIL_BLOCK + 1))
    else
      FAIL_INFO=$((FAIL_INFO + 1))
    fi
    return 1
  fi
}

# Nodos esperados según plataforma (single-node en Mac, 4 en Linux/CI)
if [ "$(uname -s)" = "Darwin" ]; then
  EXPECTED_NODES=1
else
  EXPECTED_NODES=4
fi

# ----- precondiciones -----
section "Pruebas de salida F1 — Bootstrap del cluster local"
echo "Cluster esperado: kind-$KIND_CLUSTER_NAME"
kubectl config current-context >/dev/null 2>&1 || {
  printf "\n\033[1;31m✗ ERROR:\033[0m kubectl sin contexto. ¿Corriste 'make up'?\n" >&2
  exit 2
}

# ----- F1.T-1 -----
run_test "F1.T-1" "Cluster Ready (todos los nodos)" \
  "kubectl wait --for=condition=Ready node --all --timeout=30s" \
  "condition met" "BLOQUEANTE"

# ----- F1.T-2 -----
run_test "F1.T-2" "Versión K8s 1.30.x" \
  "kubectl version -o json | jq -r .serverVersion.gitVersion" \
  "^v1\\.30\\." "BLOQUEANTE"

# ----- F1.T-3 -----
run_test "F1.T-3" "${EXPECTED_NODES} nodo(s) en el cluster (4 en CI, 1 en Mac single-node)" \
  "kubectl get nodes --no-headers | wc -l | tr -d ' '" \
  "^${EXPECTED_NODES}$" "BLOQUEANTE"

# ----- F1.T-4 -----
run_test "F1.T-4" "metrics-server operativo (${EXPECTED_NODES} nodo(s))" \
  "kubectl top nodes --no-headers | wc -l | tr -d ' '" \
  "^${EXPECTED_NODES}$" "BLOQUEANTE"

# ----- F1.T-5 -----
run_test "F1.T-5" "8 namespaces operativos creados" \
  "kubectl get ns -l app.kubernetes.io/part-of=linea-verde-experimento --no-headers | wc -l | tr -d ' '" \
  "^8$" "BLOQUEANTE"

# ----- F1.T-6 — verificación estructural Y conductual de la NetworkPolicy -----
# Estructural: el NP correcto existe en core-stub
run_test "F1.T-6a" "NetworkPolicy 'core-stub-ingress-from-acl-only' existe" \
  "kubectl get netpol -n core-stub core-stub-ingress-from-acl-only -o jsonpath='{.metadata.name}'" \
  "^core-stub-ingress-from-acl-only$" "BLOQUEANTE"

# Estructural: linea-verde NO permite egreso a core-stub
run_test "F1.T-6b" "linea-verde-egress-allowlist NO incluye core-stub" \
  "kubectl get netpol -n linea-verde linea-verde-egress-allowlist -o yaml | grep -c 'core-stub'" \
  "^0$" "BLOQUEANTE"

# Conductual: pod en linea-verde NO puede alcanzar core-stub.svc
# Solo se ejecuta si curlimages/curl está disponible y la imagen pull funciona
run_test "F1.T-6c" "Pod en linea-verde recibe HTTP 000 al intentar core-stub.svc (NetworkPolicy bloquea)" \
  "kubectl run -n linea-verde tmp-bypass-test-$$ --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet --timeout=20s -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://core-stub.core-stub.svc.cluster.local:8080/ 2>/dev/null" \
  "^000$" "BLOQUEANTE"

# ----- F1.T-7 -----
run_test "F1.T-7" "ResourceQuotas aplicadas en al menos 8 namespaces" \
  "kubectl get resourcequota -A --no-headers | grep -E 'borde|linea-verde|datos|asincrono|acl|core-stub|observabilidad|carga' | wc -l | tr -d ' '" \
  "^[8-9]$|^[1-9][0-9]+$" "BLOQUEANTE"

# ----- F1.T-8 -----
# La idempotencia se valida: aplicar 2 veces los manifiestos sin error y sin cambios.
run_test "F1.T-8" "Idempotencia: re-aplicar manifiestos no produce cambios" \
  "kubectl apply -f $ROOT_DIR/infra/k8s/00-namespaces.yaml -f $ROOT_DIR/infra/k8s/01-network-policies/ -f $ROOT_DIR/infra/k8s/02-quotas/ 2>&1 | grep -cE 'created|configured' || true" \
  "^0$" "BLOQUEANTE"

# ----- F1.T-9 — informativo -----
echo
echo "[F1.T-9 · INFORMATIVO] Tiempo total de bootstrap < 5 min"
echo "  → mide manualmente: 'time make nuke && time make up'"

# ----- resumen -----
section "Resumen del gate F1"
printf "Total tests: %d\n" "$TOTAL"
printf "  \033[1;32m✓ PASS:\033[0m         %d\n" "$PASS"
printf "  \033[1;31m✗ FAIL bloqueantes:\033[0m %d\n" "$FAIL_BLOCK"
printf "  \033[1;33m! FAIL informativos:\033[0m %d\n" "$FAIL_INFO"

if [ "$FAIL_BLOCK" -gt 0 ]; then
  printf "\n\033[1;31mGATE F1: BLOQUEADO\033[0m — %d prueba(s) bloqueante(s) fallaron. NO avanzar a F2.\n" "$FAIL_BLOCK"
  exit 1
else
  printf "\n\033[1;32mGATE F1: APROBADO\033[0m — listo para F2 (después de auditoría con architecture-reviewer).\n"
  exit 0
fi
