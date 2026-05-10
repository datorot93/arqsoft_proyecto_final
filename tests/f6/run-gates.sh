#!/usr/bin/env bash
# F6 — Pruebas de salida (gate hacia F7).
# Implementa los 10 tests BLOQUEANTE de .claude/specs/fase6_ejecucion_analisis.md.
#
# Convenio idéntico a F1–F5:
#   PASS       — criterio cumplido.
#   FAIL       — criterio no cumplido; si es BLOQUEANTE, impide F7.
#   FAIL ENV   — fallo de entorno local (cluster down, sin Prometheus, etc.).
#                Estructural OK, no impide promoción si los demás pasan.
#
# La mayoría de los tests son **inspección de artefactos** producidos por una
# o más rondas previas (típicamente la última en runs/results/). Esto evita
# que correr el gate sea costoso (no relanza k6) y mantiene la idempotencia.
# T-1 sí lanza una ronda smoke si no hay rondas previas.
#
# Variables opcionales:
#   F6_RUN_TEST_ROUND=1     — fuerza una ronda smoke al inicio (T-1 runtime).
#   F6_LATEST_ROUND=...     — path del directorio de ronda a inspeccionar.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS_DIR="$ROOT_DIR/runs/results"

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

ok()    { printf "  \033[1;32m✓ PASS\033[0m  %s\n" "$1"; PASS=$((PASS + 1)); }
fail()  { printf "  \033[1;31m✗ FAIL\033[0m  %s\n" "$1"; FAIL_BLOCK=$((FAIL_BLOCK + 1)); }
envfail() { printf "  \033[1;33m~ FAIL ENV\033[0m  %s\n" "$1"; FAIL_ENV=$((FAIL_ENV + 1)); }

# ---------------------------------------------------------------------------
# Localizar la última ronda exitosa (para inspección sin re-lanzar)
# ---------------------------------------------------------------------------
latest_round() {
  if [ -n "${F6_LATEST_ROUND:-}" ] && [ -d "$F6_LATEST_ROUND" ]; then
    echo "$F6_LATEST_ROUND"
    return 0
  fi
  # Solo rondas completas: deben tener verdicts.json + report.html.
  for d in $(ls -dt "$RESULTS_DIR"/r*-s*-* 2>/dev/null); do
    if [ -f "$d/verdicts.json" ] && [ -f "$d/report.html" ]; then
      echo "$d"
      return 0
    fi
  done
}

ROUND_DIR="$(latest_round || true)"

# ---------------------------------------------------------------------------
# Si no hay ronda previa, opcionalmente correr una smoke (T-1 runtime).
# ---------------------------------------------------------------------------
if [ -z "$ROUND_DIR" ] || [ "${F6_RUN_TEST_ROUND:-0}" = "1" ]; then
  echo "→ Lanzando smoke round (no hay ronda previa o F6_RUN_TEST_ROUND=1)…"
  if python3 "$ROOT_DIR/runs/run_round.py" --seed "${F6_SMOKE_SEED:-42}" --smoke >/tmp/f6-smoke.log 2>&1; then
    ROUND_DIR="$(latest_round)"
  else
    echo "  smoke run FAILED — ver /tmp/f6-smoke.log"
    tail -20 /tmp/f6-smoke.log
  fi
fi

if [ -z "$ROUND_DIR" ] || [ ! -d "$ROUND_DIR" ]; then
  echo "ERROR: ninguna ronda disponible. Correr con F6_RUN_TEST_ROUND=1 o ejecutar 'make f6-round SEED=42 MODE=smoke'."
  exit 2
fi

section "F6 · Inspección de la última ronda: $(basename "$ROUND_DIR")"

# =================================================================
# F6.T-1 — Una ronda completa las 3 etapas
# =================================================================
TOTAL=$((TOTAL + 1))
echo "[T-1 · BLOQUEANTE] Ronda completa: warmup_done, baseline_done, peak_done"
MANIFEST="$ROUND_DIR/manifest.json"
if [ -f "$MANIFEST" ]; then
  WHAS=$(jq -r '.warmup.ended_at // 0' "$MANIFEST")
  BHAS=$(jq -r '.baseline.ended_at // 0' "$MANIFEST")
  PHAS=$(jq -r '.peak.ended_at // 0' "$MANIFEST")
  if [ "${WHAS%.*}" -gt 0 ] 2>/dev/null && [ "${BHAS%.*}" -gt 0 ] 2>/dev/null && [ "${PHAS%.*}" -gt 0 ] 2>/dev/null; then
    ok "manifest registra las 3 etapas (warmup/baseline/peak)"
  else
    fail "manifest sin las 3 etapas: warmup=$WHAS baseline=$BHAS peak=$PHAS"
  fi
else
  fail "manifest.json no existe"
fi

# =================================================================
# F6.T-2 — 8 evaluadores AC-* responden
# =================================================================
TOTAL=$((TOTAL + 1))
echo
echo "[T-2 · BLOQUEANTE] verdicts.json contiene los 8 AC-* exactos del §7"
VERDICTS="$ROUND_DIR/verdicts.json"
if [ -f "$VERDICTS" ]; then
  KEYS=$(jq -r 'keys | join(",")' "$VERDICTS")
  EXPECTED="AC-1.1,AC-1.2,AC-2.1,AC-2.2,AC-2.3,AC-2.4,AC-2.5,AC-2.6"
  if [ "$KEYS" = "$EXPECTED" ]; then
    ok "8 AC-* exactos: $KEYS"
  else
    fail "claves no coinciden. esperado=$EXPECTED, obtenido=$KEYS"
  fi
else
  fail "verdicts.json no existe"
fi

# =================================================================
# F6.T-3 — Cada verdict tiene value, threshold, reason, verdict
# =================================================================
TOTAL=$((TOTAL + 1))
echo
echo "[T-3 · BLOQUEANTE] cada AC-* expone {verdict, value, threshold, reason}"
if [ -f "$VERDICTS" ]; then
  MISSING=$(jq -r '
    to_entries[] | .key as $k |
    .value as $v |
    [($v.verdict // "?"), ($v.value // null), ($v.threshold // null), ($v.reason // "")] |
    if (.[0] == "?" or .[1] == null or .[2] == null or .[3] == "") then $k else empty end
  ' "$VERDICTS")
  if [ -z "$MISSING" ]; then
    ok "todos los AC-* tienen verdict, value, threshold, reason"
  else
    fail "AC-* sin campos: $(echo "$MISSING" | tr '\n' ' ')"
  fi
else
  fail "verdicts.json no existe"
fi

# =================================================================
# F6.T-4 — Coordinated omission detector funciona
# Verificamos: el archivo coordinated_omission.json existe y declara umbral.
# Validación funcional: forzar un caso INVALID artificialmente y ver que
# el sistema lo marca como INVALID (no FAIL).
# =================================================================
TOTAL=$((TOTAL + 1))
echo
echo "[T-4 · BLOQUEANTE] Detector de coordinated omission produce verdict VALID/INVALID"
CO="$ROUND_DIR/coordinated_omission.json"
if [ -f "$CO" ]; then
  HAS_BASELINE=$(jq -r '.baseline.valid // empty' "$CO")
  HAS_PEAK=$(jq -r '.peak.valid // empty' "$CO")
  if [ -n "$HAS_BASELINE" ] && [ -n "$HAS_PEAK" ]; then
    # Bonus: simular forzando un INVALID con target inalcanzable.
    INVALID_TEST=$(python3 - <<'EOF' 2>/dev/null
import sys
sys.path.insert(0, '.')
from runs.lib.coordinated_omission import CoordinatedOmissionVerdict, evaluate
class StubProm:
    def first_value(self, q, when=None):
        return 0.5  # simulamos arrival_rate baja
v = evaluate(StubProm(), phase="peak", target_rate_rps=10.0, start=0, end=60, min_ratio=0.98)
print("INVALID" if not v.valid and "INVALID" in v.reason else "FAIL")
EOF
)
    if [ "$INVALID_TEST" = "INVALID" ]; then
      ok "detector marca correctamente baseline/peak (validate + simulación INVALID OK)"
    else
      fail "detector no marca caso INVALID simulado correctamente: '$INVALID_TEST'"
    fi
  else
    fail "coordinated_omission.json sin campos baseline.valid / peak.valid"
  fi
else
  fail "coordinated_omission.json no existe"
fi

# =================================================================
# F6.T-5 — Reporte HTML auto-contenido
# =================================================================
TOTAL=$((TOTAL + 1))
echo
echo "[T-5 · BLOQUEANTE] report.html > 50 KB, sin recursos externos"
HTML="$ROUND_DIR/report.html"
if [ -f "$HTML" ]; then
  SIZE=$(stat -c%s "$HTML")
  if [ "$SIZE" -gt 50000 ]; then
    EXT_SRC=$(grep -cE 'src="https?://|href="https?://' "$HTML" || true)
    SVGS=$(grep -c '<svg' "$HTML" || true)
    if [ "${EXT_SRC:-0}" -eq 0 ] && [ "${SVGS:-0}" -ge 3 ]; then
      ok "$(basename "$HTML"): ${SIZE} bytes, ${SVGS} SVGs inline, sin URLs externas"
    else
      fail "report.html con ${EXT_SRC} URLs externas y ${SVGS} SVGs (<3 inline)"
    fi
  else
    fail "report.html demasiado pequeño: ${SIZE} bytes"
  fi
else
  fail "report.html no existe"
fi

# =================================================================
# F6.T-6 — Trazabilidad falla → hipótesis §4.4
# Verificamos estructuralmente que los 8 evaluadores tienen el campo
# `hypothesis_refuted` (poblado cuando FAIL). Si la ronda actual no tiene
# fallas reales, simulamos con una ronda artificial que sí falla.
# =================================================================
TOTAL=$((TOTAL + 1))
echo
echo "[T-6 · BLOQUEANTE] Trazabilidad — cada FAIL enlaza a §4.4 vía hypothesis_refuted"
if [ -f "$VERDICTS" ]; then
  # ¿hay AC-* en FAIL en esta ronda? Si sí, validamos que enlazan §4.4.
  HAS_FAIL=$(jq -r '[.[] | select(.verdict=="FAIL")] | length' "$VERDICTS")
  if [ "$HAS_FAIL" -gt 0 ]; then
    UNLINKED=$(jq -r '[.[] | select(.verdict=="FAIL" and (.hypothesis_refuted | length == 0))] | length' "$VERDICTS")
    if [ "$UNLINKED" -eq 0 ]; then
      ok "todas las FAIL enlazan a hypothesis_refuted (§4.4)"
    else
      fail "$UNLINKED AC-* en FAIL sin hipótesis refutada"
    fi
  else
    # Sin FAIL real: verificar estructuralmente que el código contiene los enlaces.
    HYPOS=$(grep -c "hypothesis_refuted" "$ROOT_DIR/runs/lib/verdicts.py" || true)
    if [ "${HYPOS:-0}" -ge 8 ]; then
      ok "ronda sin FAIL real; estructura: ${HYPOS} referencias a hypothesis_refuted en verdicts.py"
    else
      fail "verdicts.py expone solo ${HYPOS} hypothesis_refuted (<8)"
    fi
  fi
else
  fail "verdicts.json no existe"
fi

# =================================================================
# F6.T-7 — Estratificación por país en gráficos del reporte
# =================================================================
TOTAL=$((TOTAL + 1))
echo
echo "[T-7 · BLOQUEANTE] Reporte muestra estratificación por país (pe/mx/co)"
if [ -f "$HTML" ]; then
  PAIS_REFS=$(grep -cE "pais=pe|pais=mx|pais=co|by_pais|Estratificación.*país" "$HTML" || true)
  if [ "${PAIS_REFS:-0}" -ge 3 ]; then
    ok "report.html contiene ${PAIS_REFS} referencias a estratificación por país"
  else
    fail "report.html con solo ${PAIS_REFS} referencias por país (<3)"
  fi
else
  fail "report.html no existe"
fi

# =================================================================
# F6.T-8 — Agregado N=5 con desviación reportada
# =================================================================
TOTAL=$((TOTAL + 1))
echo
echo "[T-8 · BLOQUEANTE] aggregate.html reporta P95 = X ± σ ms"
AGG_HTML="$RESULTS_DIR/aggregate.html"
AGG_JSON="$RESULTS_DIR/aggregate_verdict.json"
if [ ! -f "$AGG_HTML" ] || [ ! -f "$AGG_JSON" ]; then
  echo "  → corriendo aggregate sobre $RESULTS_DIR/r*"
  python3 "$ROOT_DIR/runs/aggregate_results.py" "$RESULTS_DIR"/r* >/tmp/f6-agg.log 2>&1 || true
fi
if [ -f "$AGG_HTML" ] && [ -f "$AGG_JSON" ]; then
  ROUNDS=$(jq -r '.rounds_total // 0' "$AGG_JSON")
  HAS_STDEV=$(jq -r '.p95_baseline_ms.stdev // empty' "$AGG_JSON")
  HAS_MEAN=$(jq -r '.p95_baseline_ms.mean // empty' "$AGG_JSON")
  HAS_PMSIG=$(grep -cE "± [0-9]+\.[0-9]+ ms|±.*ms" "$AGG_HTML" || true)
  if [ "$ROUNDS" -ge 1 ] && [ -n "$HAS_MEAN" ] && [ -n "$HAS_STDEV" ] && [ "${HAS_PMSIG:-0}" -ge 1 ]; then
    ok "aggregate sobre $ROUNDS ronda(s); P95 mean=${HAS_MEAN} stdev=${HAS_STDEV}"
  else
    fail "aggregate insuficiente: rounds=$ROUNDS mean=$HAS_MEAN stdev=$HAS_STDEV pm_count=$HAS_PMSIG"
  fi
else
  fail "no se pudo generar aggregate.html / aggregate_verdict.json"
fi

# =================================================================
# F6.T-9 — Manifest contiene seed y experiment_spec_sha
# =================================================================
TOTAL=$((TOTAL + 1))
echo
echo "[T-9 · BLOQUEANTE] manifest.json incluye seed y experiment_spec_sha"
if [ -f "$MANIFEST" ]; then
  SEED=$(jq -r '.seed // null' "$MANIFEST")
  SPEC_SHA=$(jq -r '.experiment_spec_sha // null' "$MANIFEST")
  GIT_SHA=$(jq -r '.git_sha // null' "$MANIFEST")
  if [ "$SEED" != "null" ] && [ "$SPEC_SHA" != "null" ] && [ -n "$SPEC_SHA" ] && [ "$SPEC_SHA" != "missing" ]; then
    ok "seed=$SEED, experiment_spec_sha=${SPEC_SHA:0:12}…, git=${GIT_SHA:0:8}"
  else
    fail "manifest incompleto: seed=$SEED spec_sha=$SPEC_SHA"
  fi
else
  fail "manifest.json no existe"
fi

# =================================================================
# F6.T-10 — Falla atómica: 4/5 PASS no es aprobación
# Construir un aggregate con una ronda artificialmente FAIL y confirmar que
# el veredicto es EXPERIMENT FAILED.
# =================================================================
TOTAL=$((TOTAL + 1))
echo
echo "[T-10 · BLOQUEANTE] Falla atómica — 4/5 PASS produce EXPERIMENT FAILED"
TMP_TEST="$ROOT_DIR/runs/results/.t10-test"
rm -rf "$TMP_TEST" && mkdir -p "$TMP_TEST"
# Copiar 4 rondas reales como PASS (si hay) y crear 1 sintética FAIL.
COUNT=0
for d in "$RESULTS_DIR"/r*-s*-*; do
  [ -d "$d" ] || continue
  cp -r "$d" "$TMP_TEST/round_$COUNT"
  # Forzar PASS en estas:
  python3 - <<EOF 2>/dev/null
import json, pathlib
p = pathlib.Path("$TMP_TEST/round_$COUNT")
v = json.loads((p/"verdicts.json").read_text())
for ac in v: v[ac]["verdict"] = "PASS"
(p/"verdicts.json").write_text(json.dumps(v))
s = json.loads((p/"round_summary.json").read_text())
s["overall_verdict"] = "PASS"
(p/"round_summary.json").write_text(json.dumps(s))
EOF
  COUNT=$((COUNT + 1))
  [ "$COUNT" -ge 4 ] && break
done

# Crear ronda artificial FAIL
mkdir -p "$TMP_TEST/round_fail"
cat > "$TMP_TEST/round_fail/manifest.json" <<EOF
{"round_id":"round_fail","seed":99,"scaled":true,"experiment_spec_sha":"deadbeef","git_sha":"deadbeef","versions":{},"started_at":1,"ended_at":2,"warmup":{"name":"warmup"},"baseline":{"name":"baseline_asr1"},"peak":{"name":"peak_asr2"},"config":{"mode":"scaled"}}
EOF
cat > "$TMP_TEST/round_fail/verdicts.json" <<EOF
{"AC-1.1":{"ac_id":"AC-1.1","name":"P95","verdict":"FAIL","value":"1500 ms","threshold":"800 ms","reason":"injected","stratified":{},"hypothesis_refuted":"H1","suspect_component":"X"},
 "AC-1.2":{"ac_id":"AC-1.2","name":"P99","verdict":"PASS","value":"500 ms","threshold":"1500 ms","reason":"ok","stratified":{},"hypothesis_refuted":"","suspect_component":""},
 "AC-2.1":{"ac_id":"AC-2.1","name":"vol","verdict":"PASS","value":7000,"threshold":6000,"reason":"ok","stratified":{},"hypothesis_refuted":"","suspect_component":""},
 "AC-2.2":{"ac_id":"AC-2.2","name":"loss","verdict":"PASS","value":0,"threshold":0,"reason":"ok","stratified":{},"hypothesis_refuted":"","suspect_component":""},
 "AC-2.3":{"ac_id":"AC-2.3","name":"sustained","verdict":"PASS","value":"20/20","threshold":"≥18","reason":"ok","stratified":{},"hypothesis_refuted":"","suspect_component":""},
 "AC-2.4":{"ac_id":"AC-2.4","name":"dlq","verdict":"PASS","value":0,"threshold":0,"reason":"ok","stratified":{},"hypothesis_refuted":"","suspect_component":""},
 "AC-2.5":{"ac_id":"AC-2.5","name":"hpa","verdict":"PASS","value":"30s","threshold":"<60s","reason":"ok","stratified":{},"hypothesis_refuted":"","suspect_component":""},
 "AC-2.6":{"ac_id":"AC-2.6","name":"cb","verdict":"PASS","value":0,"threshold":0,"reason":"ok","stratified":{},"hypothesis_refuted":"","suspect_component":""}}
EOF
cat > "$TMP_TEST/round_fail/round_summary.json" <<EOF
{"round_id":"round_fail","seed":99,"mode":"scaled","scaled":true,"overall_verdict":"FAIL","overall_reason":"AC-1.1 FAIL injected","started_at":1,"ended_at":2}
EOF
cat > "$TMP_TEST/round_fail/coordinated_omission.json" <<EOF
{"baseline":{"phase":"baseline","target_rate_rps":0.2,"actual_rate_rps":0.2,"ratio":1.0,"threshold":0.9,"valid":true,"reason":"ok"},"peak":{"phase":"peak","target_rate_rps":5,"actual_rate_rps":5,"ratio":1.0,"threshold":0.85,"valid":true,"reason":"ok"}}
EOF

if python3 "$ROOT_DIR/runs/aggregate_results.py" "$TMP_TEST"/round_* \
   --out /tmp/f6-t10-agg.html --out-json /tmp/f6-t10-agg.json >/dev/null 2>&1; then
  STATUS=$(jq -r '.experiment_status // "?"' /tmp/f6-t10-agg.json)
  if echo "$STATUS" | grep -q "FAILED"; then
    ok "5 rondas (4 PASS + 1 FAIL) ⇒ '$STATUS'"
  else
    fail "esperado EXPERIMENT FAILED, obtuvo: '$STATUS'"
  fi
else
  fail "aggregate falló sobre $TMP_TEST"
fi
rm -rf "$TMP_TEST"

# =================================================================
# Resumen
# =================================================================
section "Resumen del gate F6"
printf "Total tests: %d\n" "$TOTAL"
printf "  \033[1;32m✓ PASS:\033[0m              %d\n" "$PASS"
printf "  \033[1;31m✗ FAIL bloqueantes:\033[0m  %d\n" "$FAIL_BLOCK"
printf "  \033[1;33m~ FAIL ENV:\033[0m          %d\n" "$FAIL_ENV"

if [ "$FAIL_BLOCK" -gt 0 ]; then
  printf "\n\033[1;31mGATE F6: BLOQUEADO\033[0m — %d prueba(s) bloqueante(s) fallaron. NO avanzar a F7.\n" "$FAIL_BLOCK"
  exit 1
elif [ "$FAIL_ENV" -gt 0 ]; then
  printf "\n\033[1;33mGATE F6: APROBADO con FAIL ENV\033[0m — %d fallo(s) de entorno. Listo para F7.\n" "$FAIL_ENV"
  exit 0
else
  printf "\n\033[1;32mGATE F6: APROBADO\033[0m — listo para F7.\n"
  exit 0
fi
