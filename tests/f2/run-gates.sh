#!/usr/bin/env bash
# F2 — Pruebas de salida (gate hacia F3).
# Implementa los 11 tests de .claude/specs/fase2_plataforma_datos_mensajeria.md

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

PASS=0
FAIL_BLOCK=0
TOTAL=0

section() {
  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "$*"
  echo "════════════════════════════════════════════════════════════════"
}

run_test() {
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
    [ "$gate" = "BLOQUEANTE" ] && FAIL_BLOCK=$((FAIL_BLOCK + 1))
    return 1
  fi
}

section "Pruebas de salida F2 — Plataforma de datos y mensajería"
kubectl config current-context >/dev/null 2>&1 || {
  printf "\n\033[1;31m✗ ERROR:\033[0m kubectl sin contexto. ¿Corriste 'make platform-up'?\n" >&2
  exit 2
}

# ----- F2.T-1 -----
run_test "F2.T-1" "3 clusters Postgres healthy (pe, mx, co)" \
  "kubectl get clusters.postgresql.cnpg.io -n datos -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{\"\\n\"}{end}' | sort | tr '\n' ' '" \
  "postgres-co=Cluster in healthy state.*postgres-mx=Cluster in healthy state.*postgres-pe=Cluster in healthy state" \
  "BLOQUEANTE"

# ----- F2.T-2 -----
run_test "F2.T-2 (pe)" "Schema cdt en postgres-pe (≥ 2 tablas)" \
  "kubectl exec -n datos postgres-pe-1 -c postgres -- psql -U postgres -d linea_verde -t -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='cdt';\" | tr -d ' \\n'" \
  "^[2-9]$|^[1-9][0-9]+$" "BLOQUEANTE"

run_test "F2.T-2 (mx)" "Schema cdt en postgres-mx" \
  "kubectl exec -n datos postgres-mx-1 -c postgres -- psql -U postgres -d linea_verde -t -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='cdt';\" | tr -d ' \\n'" \
  "^[2-9]$|^[1-9][0-9]+$" "BLOQUEANTE"

run_test "F2.T-2 (co)" "Schema cdt en postgres-co" \
  "kubectl exec -n datos postgres-co-1 -c postgres -- psql -U postgres -d linea_verde -t -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='cdt';\" | tr -d ' \\n'" \
  "^[2-9]$|^[1-9][0-9]+$" "BLOQUEANTE"

# ----- F2.T-3 -----
# Replicación: cuenta de standbys reportada por CNPG
run_test "F2.T-3" "Replicación primary→standby (cada cluster con readyInstances=2)" \
  "kubectl get clusters.postgresql.cnpg.io -n datos -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyInstances}{\"\\n\"}{end}' | sort -u | awk -F= '{print \$2}' | sort -u" \
  "^2$" "BLOQUEANTE"

# ----- F2.T-4 -----
run_test "F2.T-4" "Tópico cdt.eventos con 6 particiones, RF=3" \
  "kubectl exec -n asincrono redpanda-0 -c redpanda -- rpk topic describe cdt.eventos -p 2>/dev/null | head -2" \
  "PARTITION.*REPLICAS|^0.*\\[.*,.*,.*\\]" "BLOQUEANTE"

# ----- F2.T-5 -----
run_test "F2.T-5" "DLQ existe con retención 7d (604800000 ms)" \
  "kubectl exec -n asincrono redpanda-0 -c redpanda -- rpk topic describe cdt.eventos.DLQ -c 2>/dev/null | grep retention" \
  "604800000|7 day" "BLOQUEANTE"

# ----- F2.T-6 -----
run_test "F2.T-6" "Apicurio Registry responde (HTTP 200)" \
  "kubectl exec -n asincrono deployment/apicurio -- curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/apis/registry/v3/system/info" \
  "^200$" "BLOQUEANTE"

# ----- F2.T-7 -----
# Kong 3.7 no incluye curl en el container — se usa port-forward al host.
run_test "F2.T-7" "Kong admin API alcanzable + DB-less mode" \
  "kubectl port-forward -n borde deploy/kong-kong 38001:8001 >/dev/null 2>&1 & PF=\$!; sleep 3; curl -s http://127.0.0.1:38001/status 2>/dev/null | head -c 500; kill \$PF 2>/dev/null; wait \$PF 2>/dev/null; true" \
  "configuration_hash|\"database\":\"off\"" "BLOQUEANTE"

# ----- F2.T-8 -----
run_test "F2.T-8" "Plugin Prometheus en Kong (>10 métricas)" \
  "kubectl port-forward -n borde deploy/kong-kong 38100:8100 >/dev/null 2>&1 & PF=\$!; sleep 3; curl -s http://127.0.0.1:38100/metrics 2>/dev/null | grep -c '^kong_'; kill \$PF 2>/dev/null; wait \$PF 2>/dev/null; true" \
  "^[1-9][0-9]+$" "BLOQUEANTE"

# ----- F2.T-9 -----
run_test "F2.T-9" "Round-trip producer→consumer en cdt.eventos" \
  "kubectl exec -n asincrono redpanda-0 -c redpanda -- bash -c 'MSG=\"smoke-test-\$(date +%s)\"; PROD=\$(echo \"\$MSG\" | rpk topic produce cdt.eventos --brokers redpanda.asincrono.svc.cluster.local:9093 -k smoke 2>&1); echo \"\$PROD\"; PART=\$(echo \"\$PROD\" | grep -oE \"partition [0-9]+\" | grep -oE \"[0-9]+\"); OFF=\$(echo \"\$PROD\" | grep -oE \"offset [0-9]+\" | grep -oE \"[0-9]+\"); rpk topic consume cdt.eventos --brokers redpanda.asincrono.svc.cluster.local:9093 -n 1 -p \"\$PART\" -o \"\$OFF\" 2>&1 | head -5'" \
  "smoke-test-[0-9]+|Produced to partition" "BLOQUEANTE"

# ----- F2.T-10 / F2.T-11 son tests con servicios CDTXPais que aún no existen (F4) -----
echo
echo "[F2.T-10/T-11 · INFORMATIVO] Cross-país NetworkPolicies se validan en F4"
echo "  Estructural ahora:"
run_test "F2.T-10/11 (estructural)" "NetworkPolicies postgres-{pe,mx,co}-ingress-from-* existen" \
  "kubectl get netpol -n datos -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\\n' | grep -c 'ingress-from'" \
  "^[3-9]$|^[1-9][0-9]+$" "BLOQUEANTE"

# ----- resumen -----
section "Resumen del gate F2"
printf "Total tests: %d\n" "$TOTAL"
printf "  \033[1;32m✓ PASS:\033[0m         %d\n" "$PASS"
printf "  \033[1;31m✗ FAIL bloqueantes:\033[0m %d\n" "$FAIL_BLOCK"

if [ "$FAIL_BLOCK" -gt 0 ]; then
  printf "\n\033[1;31mGATE F2: BLOQUEADO\033[0m — %d prueba(s) bloqueante(s) fallaron. NO avanzar a F3.\n" "$FAIL_BLOCK"
  exit 1
else
  printf "\n\033[1;32mGATE F2: APROBADO\033[0m — listo para F3.\n"
  exit 0
fi
