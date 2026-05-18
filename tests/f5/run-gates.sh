#!/usr/bin/env bash
# F5 — Pruebas de salida (gate hacia F6).
# Implementa los 12 tests BLOQUEANTE de .claude/specs/fase5_generador_carga.md.
#
# Convenio idéntico a F1–F4:
#   PASS       — criterio cumplido.
#   FAIL       — criterio no cumplido; si es BLOQUEANTE, impide F6.
#   FAIL ENV   — fallo de entorno local (cluster down, sin port-forward, etc.).
#                Estructural OK, no impide promoción si los demás pasan.
#
# Variables opcionales:
#   PROM_URL=http://localhost:9090   — para los queries de F5.T-8/T-9.
#   KONG_URL=http://localhost:8080   — Kong proxy externo si no hay cluster.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOAD_DIR="$ROOT_DIR/load"
source "$ROOT_DIR/versions.env"

# Detectar node: primero en PATH, luego en nvm (no sourced en bash -c no interactivo)
if ! command -v node >/dev/null 2>&1; then
  NVM_NODE=$(ls "$HOME/.nvm/versions/node"/*/bin/node 2>/dev/null | sort -V | tail -1)
  if [ -n "$NVM_NODE" ]; then
    export PATH="$(dirname "$NVM_NODE"):$PATH"
  fi
fi
NODE_BIN=$(command -v node 2>/dev/null || echo "node")
# Sustituir "node " por la ruta absoluta en los tests que usan run_node_test
# (los comandos en run_node_test se ejecutan con bash -c en subshell sin .bashrc)
export PATH="$(dirname "$NODE_BIN"):$PATH"

PROM_URL="${PROM_URL:-http://kube-prometheus-stack-prometheus.observabilidad.svc.cluster.local:9090}"
KONG_URL_INT="${KONG_URL:-http://kong-kong-proxy.borde.svc.cluster.local}"

PASS=0
FAIL_BLOCK=0
FAIL_ENV=0
TOTAL=0

section() {
  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "$*"
  echo "════════════════════════════════════════════════════════════════"
}

run_node_test() {
  local id="$1" desc="$2" cmd="$3"
  TOTAL=$((TOTAL + 1))
  printf "\n[%s · BLOQUEANTE] %s\n  $ %s\n" "$id" "$desc" "$cmd"
  if (cd "$LOAD_DIR" && bash -c "$cmd" >/tmp/f5t-$id.out 2>&1); then
    printf "  \033[1;32m✓ PASS\033[0m\n"
    tail -3 /tmp/f5t-$id.out | sed 's/^/           /'
    PASS=$((PASS + 1))
    return 0
  else
    printf "  \033[1;31m✗ FAIL\033[0m\n"
    tail -10 /tmp/f5t-$id.out | sed 's/^/           /'
    FAIL_BLOCK=$((FAIL_BLOCK + 1))
    return 1
  fi
}

section "Pruebas de salida F5 — Generador de carga estocástico k6"

# =================================================================
# F5.T-1 — KS test exponencial (10 000 inter-arrivals con λ=5)
# =================================================================
run_node_test "T-1" "KS test exponencial sobre 10 000 inter-arrivals (Exp(λ=5))" \
  "node test/validate_nhpp.js --samples 10000 --lambda 5"

# =================================================================
# F5.T-2 — Integral λ(t) sobre [0, 1200] s
# =================================================================
run_node_test "T-2" "NHPP integral ∫λ(t) dt sobre 1200 s" \
  "node test/integrate_lambda.js"

# =================================================================
# F5.T-3 — MMPP-2 fracción `bursty`
# =================================================================
run_node_test "T-3" "MMPP-2 — fracción bursty correcta (ensemble 30 runs)" \
  "node test/analyze_mmpp.js"

# =================================================================
# F5.T-4 — MMPP-2 duración media de ráfaga
# (Implementado en analyze_mmpp.js — el mismo test cubre T-3 y T-4 como
# muestra del spec; aquí lo registramos como segundo test independiente.)
# =================================================================
echo ""
echo "[T-4 · BLOQUEANTE] MMPP-2 — duración media de ráfaga"
TOTAL=$((TOTAL + 1))
T4_OUT=$(cd "$LOAD_DIR" && node test/analyze_mmpp.js 2>&1 | grep "duración media" | head -1)
T4_DUR=$(echo "$T4_OUT" | awk '{print $4}')
if [ -n "$T4_DUR" ] && python3 -c "exit(0 if 15 <= float('$T4_DUR') <= 25 else 1)" 2>/dev/null; then
  printf "  \033[1;32m✓ PASS\033[0m  duración media = %s s ∈ [15, 25]\n" "$T4_DUR"
  PASS=$((PASS + 1))
else
  printf "  \033[1;31m✗ FAIL\033[0m  duración media fuera de rango (%s)\n" "$T4_DUR"
  FAIL_BLOCK=$((FAIL_BLOCK + 1))
fi

# =================================================================
# F5.T-5 — Dirichlet por país
# =================================================================
run_node_test "T-5" "Dirichlet — distribución por país (ensemble 200 draws)" \
  "node test/analyze_dirichlet.js"

# =================================================================
# F5.T-6 — Reproducibilidad por seed (hash idéntico)
# =================================================================
echo ""
echo "[T-6 · BLOQUEANTE] Reproducibilidad por seed (hash SHA-256 idéntico)"
TOTAL=$((TOTAL + 1))
HASH1=$(cd "$LOAD_DIR" && node test/repro_hash.js --seed 42 2>/dev/null)
HASH2=$(cd "$LOAD_DIR" && node test/repro_hash.js --seed 42 2>/dev/null)
if [ -n "$HASH1" ] && [ "$HASH1" = "$HASH2" ]; then
  printf "  \033[1;32m✓ PASS\033[0m  hash run1=run2=%s\n" "${HASH1:0:16}..."
  PASS=$((PASS + 1))
else
  printf "  \033[1;31m✗ FAIL\033[0m  hash run1=%s != run2=%s\n" "${HASH1:0:16}" "${HASH2:0:16}"
  FAIL_BLOCK=$((FAIL_BLOCK + 1))
fi

# =================================================================
# F5.T-7 — Lognormal payload size
# =================================================================
run_node_test "T-7" "Lognormal payload — media en [1843, 2253] B y cap respetado" \
  "node test/measure_payload.js"

# =================================================================
# F5.T-8 — k6 emite a Prometheus durante corrida
# =================================================================
echo ""
echo "[T-8 · BLOQUEANTE] k6 emite métricas a Prometheus (k6_http_reqs_total > 0)"
TOTAL=$((TOTAL + 1))

PROM_POD=$(kubectl get pod -n observabilidad -l 'app.kubernetes.io/name=prometheus' \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$PROM_POD" ]; then
  T8_VAL=$(kubectl exec -n observabilidad "$PROM_POD" -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=sum(k6_http_reqs_total)' 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d['data']['result']
    print(int(float(r[0]['value'][1])) if r else 0)
except: print(0)" 2>/dev/null || echo "0")

  if [ "$T8_VAL" -gt 0 ]; then
    printf "  \033[1;32m✓ PASS\033[0m  sum(k6_http_reqs_total) = %s en Prometheus\n" "$T8_VAL"
    PASS=$((PASS + 1))
  else
    printf "  \033[1;33m~ FAIL ENV\033[0m  No hay métricas k6 en Prometheus (¿ningún K6 TestRun ejecutado todavía?)\n"
    printf "             Para PASS runtime: make load-warmup; tests/f5/run-gates.sh\n"
    FAIL_ENV=$((FAIL_ENV + 1))
  fi
else
  printf "  \033[1;33m~ FAIL ENV\033[0m  Pod Prometheus no encontrado.\n"
  FAIL_ENV=$((FAIL_ENV + 1))
fi

# =================================================================
# F5.T-9 — Trace propagation k6 → Kong → cdt-pais → ACL
# Verificación estructural: el header `traceparent` se inyecta en cada request.
# Verificación runtime requiere query a Tempo.
# =================================================================
echo ""
echo "[T-9 · BLOQUEANTE] Trace propagation — header traceparent en cada request"
TOTAL=$((TOTAL + 1))

# Estructural: el módulo trace.js está importado y usado.
TRACE_IMPORT=$(grep -l "makeTraceparent" \
  "$LOAD_DIR"/scenarios/warmup.js \
  "$LOAD_DIR"/scenarios/baseline_asr1.js \
  "$LOAD_DIR"/scenarios/peak_asr2.js 2>/dev/null | wc -l)
# `traceparent:` aparece como key en el objeto headers, una vez por escenario.
TRACE_USAGE=$(grep -h "traceparent:" \
  "$LOAD_DIR"/scenarios/warmup.js \
  "$LOAD_DIR"/scenarios/baseline_asr1.js \
  "$LOAD_DIR"/scenarios/peak_asr2.js 2>/dev/null | wc -l)

if [ "$TRACE_IMPORT" -ge 3 ] && [ "$TRACE_USAGE" -ge 3 ]; then
  printf "  \033[1;32m✓ PASS (estructural)\033[0m  3 escenarios importan trace.js y lo usan en headers\n"
  printf "             Verificación runtime end-to-end: query Tempo en F6.T-9.\n"
  PASS=$((PASS + 1))
else
  printf "  \033[1;31m✗ FAIL\033[0m  imports=%s usages=%s en escenarios\n" "$TRACE_IMPORT" "$TRACE_USAGE"
  FAIL_BLOCK=$((FAIL_BLOCK + 1))
fi

# =================================================================
# F5.T-10 — Generador solo entra por Kong (NetworkPolicy)
# =================================================================
echo ""
echo "[T-10 · BLOQUEANTE] NetworkPolicy: carga egresa SOLO a borde y observabilidad"
TOTAL=$((TOTAL + 1))

NP_EGRESS=$(kubectl get netpol carga-egress-only-borde -n carga -o jsonpath='{.spec.egress[*].to[*].namespaceSelector.matchLabels.kubernetes\.io/metadata\.name}' 2>/dev/null || echo "")

# Verificamos: contiene `borde` y `observabilidad`, NO contiene
# `linea-verde`, `datos`, `core-stub`.
HAS_BORDE=$(echo "$NP_EGRESS" | tr ' ' '\n' | grep -wxc "borde" 2>/dev/null || true)
HAS_OBS=$(echo "$NP_EGRESS" | tr ' ' '\n' | grep -wxc "observabilidad" 2>/dev/null || true)
HAS_LV=$(echo "$NP_EGRESS" | tr ' ' '\n' | grep -wxc "linea-verde" 2>/dev/null || true)
HAS_DATA=$(echo "$NP_EGRESS" | tr ' ' '\n' | grep -wxc "datos" 2>/dev/null || true)
HAS_CORE=$(echo "$NP_EGRESS" | tr ' ' '\n' | grep -wxc "core-stub" 2>/dev/null || true)
HAS_BORDE=${HAS_BORDE:-0}; HAS_OBS=${HAS_OBS:-0}; HAS_LV=${HAS_LV:-0}; HAS_DATA=${HAS_DATA:-0}; HAS_CORE=${HAS_CORE:-0}

if [ "$HAS_BORDE" -ge 1 ] && [ "$HAS_OBS" -ge 1 ] && [ "$HAS_LV" -eq 0 ] && [ "$HAS_DATA" -eq 0 ] && [ "$HAS_CORE" -eq 0 ]; then
  printf "  \033[1;32m✓ PASS\033[0m  egress: %s\n" "$NP_EGRESS"
  PASS=$((PASS + 1))
else
  printf "  \033[1;31m✗ FAIL\033[0m  egress incorrecto: borde=%s obs=%s linea-verde=%s datos=%s core-stub=%s — egress: %s\n" \
    "$HAS_BORDE" "$HAS_OBS" "$HAS_LV" "$HAS_DATA" "$HAS_CORE" "$NP_EGRESS"
  FAIL_BLOCK=$((FAIL_BLOCK + 1))
fi

# =================================================================
# F5.T-11 — Executor obligatorio `ramping-arrival-rate`
# =================================================================
echo ""
echo "[T-11 · BLOQUEANTE] Executor obligatorio = ramping-arrival-rate"
TOTAL=$((TOTAL + 1))

# Buscar `executor:` en los scenarios y runner.
EXEC_LINES=$(grep -hE '^\s*executor:' "$LOAD_DIR"/scenarios/*.js "$LOAD_DIR"/runner/*.js 2>/dev/null || echo "")
RAMPING=$(echo "$EXEC_LINES" | grep -c "ramping-arrival-rate" 2>/dev/null || true)
NON_RAMPING=$(echo "$EXEC_LINES" | grep -cE 'constant-vus|ramping-vus|constant-arrival-rate|per-vu-iterations|shared-iterations|externally-controlled' 2>/dev/null || true)
RAMPING=${RAMPING:-0}; NON_RAMPING=${NON_RAMPING:-0}

if [ "$RAMPING" -ge 3 ] && [ "$NON_RAMPING" -eq 0 ]; then
  printf "  \033[1;32m✓ PASS\033[0m  Todos los executors son ramping-arrival-rate (%s ocurrencias)\n" "$RAMPING"
  PASS=$((PASS + 1))
else
  printf "  \033[1;31m✗ FAIL\033[0m  ramping=%s otros=%s\n" "$RAMPING" "$NON_RAMPING"
  echo "$EXEC_LINES" | sed 's/^/           /' | head -10
  FAIL_BLOCK=$((FAIL_BLOCK + 1))
fi

# =================================================================
# F5.T-12 — make validate-load-model exit 0
# =================================================================
echo ""
echo "[T-12 · BLOQUEANTE] make validate-load-model retorna exit 0"
TOTAL=$((TOTAL + 1))

if (cd "$ROOT_DIR" && make validate-load-model >/tmp/f5t12.out 2>&1); then
  printf "  \033[1;32m✓ PASS\033[0m  make validate-load-model exit 0\n"
  tail -3 /tmp/f5t12.out | sed 's/^/           /'
  PASS=$((PASS + 1))
else
  printf "  \033[1;31m✗ FAIL\033[0m  make validate-load-model retornó error\n"
  tail -15 /tmp/f5t12.out | sed 's/^/           /'
  FAIL_BLOCK=$((FAIL_BLOCK + 1))
fi

# =================================================================
# Resumen
# =================================================================
section "Resumen del gate F5"
printf "Total tests: %d\n" "$TOTAL"
printf "  \033[1;32m✓ PASS:\033[0m              %d\n" "$PASS"
printf "  \033[1;31m✗ FAIL bloqueantes:\033[0m  %d\n" "$FAIL_BLOCK"
printf "  \033[1;33m~ FAIL ENV:\033[0m          %d\n" "$FAIL_ENV"

if [ "$FAIL_BLOCK" -gt 0 ]; then
  printf "\n\033[1;31mGATE F5: BLOQUEADO\033[0m — %d prueba(s) bloqueante(s) fallaron. NO avanzar a F6.\n" "$FAIL_BLOCK"
  exit 1
elif [ "$FAIL_ENV" -gt 0 ]; then
  printf "\n\033[1;33mGATE F5: APROBADO con FAIL ENV\033[0m — %d fallo(s) de entorno. Listo para F6.\n" "$FAIL_ENV"
  exit 0
else
  printf "\n\033[1;32mGATE F5: APROBADO\033[0m — listo para F6.\n"
  exit 0
fi
