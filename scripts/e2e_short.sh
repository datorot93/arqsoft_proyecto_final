#!/usr/bin/env bash
# scripts/e2e_short.sh — smoke E2E corto para F8.
#
# Variante reducida del experimento:
#   warmup 2 min + baseline 3 min + peak 5 min = ~10 min de carga
#   Volumen objetivo: ~1500 CDT en 5 min (4× la tasa media del peak completo).
#
# Diferencia con --scaled:
#   --scaled: warmup 60s + baseline 180s + peak 240s → threshold 1200
#   --e2e-short: warmup 120s + baseline 180s + peak 300s → threshold 1500
#
# Salida:
#   runs/results/e2e-short/report.html     (reporte HTML con veredictos)
#   runs/results/e2e-short/verdicts.json   (AC-* individuales)
#
# NOTA: Este es un smoke test estructural, NO el veredicto autoritativo.
#        El veredicto final del experimento se emite con 'make e2e-full'
#        (N=5 rondas con duraciones completas según §7 del documento maestro).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

E2E_SHORT_OUT="${ROOT_DIR}/runs/results/e2e-short"

echo "================================================================"
echo " F8 — smoke E2E corto"
echo " warmup=120s  baseline=180s  peak=300s  threshold=1500"
echo " NOTA: Smoke test estructural — no autoritativo (ver 'make e2e-full')"
echo "================================================================"
echo ""

# -----------------------------------------------------------------------
# Paso 1: verificar que el cluster y los servicios estén corriendo.
# Si no están, levantar idempotente.
# -----------------------------------------------------------------------
echo "[e2e-short] Verificando cluster..."
if ! kind get clusters 2>/dev/null | grep -q "${KIND_CLUSTER_NAME:-linea-verde}"; then
    echo "[e2e-short] Cluster no encontrado. Ejecutando make up..."
    make -C "$ROOT_DIR" up
fi

echo "[e2e-short] Verificando namespaces..."
for ns in linea-verde asincrono datos borde observabilidad carga; do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "[e2e-short] Namespace $ns no existe. El cluster puede estar incompleto."
        echo "[e2e-short] Ejecuta: make up && make platform-up && make observability-up && make services-build && make services-deploy && make load-build && make load-deploy"
        exit 1
    fi
done

# Verificar que los pods de la ruta crítica estén Running
echo "[e2e-short] Verificando pods de la ruta crítica..."
for ns_pod in "linea-verde:cdt-pais" "borde:kong" "datos:postgres" "asincrono:redpanda"; do
    ns="${ns_pod%%:*}"
    label="${ns_pod##*:}"
    if ! kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep "$label" | grep -q "Running"; then
        echo "[e2e-short] ADVERTENCIA: Pods de '$label' en namespace '$ns' no están Running."
        echo "[e2e-short] Intentando desplegar servicios y carga..."
        make -C "$ROOT_DIR" services-deploy || true
        make -C "$ROOT_DIR" load-deploy || true
        sleep 10
    fi
done

echo "[e2e-short] Pre-checks OK."
echo ""

# -----------------------------------------------------------------------
# Paso 2: lanzar la ronda con duraciones del e2e-short.
# Usamos el modo --scaled como base pero pasamos --out para separar el dir.
# El script run_round.py soporta DURATIONS dict; añadimos 'e2e-short' via env.
# -----------------------------------------------------------------------
echo "[e2e-short] Lanzando ronda smoke E2E (warmup=120s baseline=180s peak=300s)..."
mkdir -p "$E2E_SHORT_OUT"

python3 "${ROOT_DIR}/runs/run_round.py" \
    --seed 42 \
    --e2e-short \
    --out "$E2E_SHORT_OUT" \
    2>&1 | tee "${E2E_SHORT_OUT}/run.log"

ROUND_STATUS=$?

if [ "$ROUND_STATUS" -ne 0 ]; then
    echo ""
    echo "[e2e-short] ERROR: La ronda falló (exit $ROUND_STATUS)."
    echo "[e2e-short] Ver log: ${E2E_SHORT_OUT}/run.log"
    exit 1
fi

# -----------------------------------------------------------------------
# Paso 3: copiar el reporte y verdicts al directorio canónico e2e-short/.
# run_round.py escribe en e2e-short/<round_id>/ — buscamos el más reciente.
# -----------------------------------------------------------------------
LATEST_ROUND=$(ls -dt "${E2E_SHORT_OUT}"/r*-s42-e2e-short 2>/dev/null | head -1)

if [ -z "$LATEST_ROUND" ]; then
    # Intentar cualquier ronda generada
    LATEST_ROUND=$(ls -dt "${E2E_SHORT_OUT}"/r* 2>/dev/null | head -1)
fi

if [ -n "$LATEST_ROUND" ] && [ -d "$LATEST_ROUND" ]; then
    echo "[e2e-short] Ronda generada: $LATEST_ROUND"

    # Copiar artefactos al directorio raíz del e2e-short para acceso directo
    [ -f "${LATEST_ROUND}/report.html" ]   && cp "${LATEST_ROUND}/report.html"   "${E2E_SHORT_OUT}/report.html"
    [ -f "${LATEST_ROUND}/verdicts.json" ] && cp "${LATEST_ROUND}/verdicts.json" "${E2E_SHORT_OUT}/verdicts.json"
    [ -f "${LATEST_ROUND}/round_summary.json" ] && cp "${LATEST_ROUND}/round_summary.json" "${E2E_SHORT_OUT}/summary.json"
fi

# -----------------------------------------------------------------------
# Paso 4: imprimir veredicto y advertencia sobre autoridad del resultado.
# -----------------------------------------------------------------------
echo ""
echo "================================================================"
echo " Resultado del smoke E2E corto"
echo "================================================================"

if [ -f "${E2E_SHORT_OUT}/verdicts.json" ]; then
    echo ""
    echo "Veredictos AC-*:"
    python3 -c "
import json, sys
try:
    data = json.load(open('${E2E_SHORT_OUT}/verdicts.json'))
    ac_order = ['AC-1.1','AC-1.2','AC-2.1','AC-2.2','AC-2.3','AC-2.4','AC-2.5','AC-2.6']
    pass_count = sum(1 for ac in ac_order if data.get(ac, {}).get('verdict') in ('PASS','NA'))
    for ac in ac_order:
        v = data.get(ac, {})
        verdict = v.get('verdict','?')
        value   = v.get('value','')
        marker = chr(10003) if verdict in ('PASS','NA') else chr(10007)
        print(f'  {marker} {ac}: {verdict}  (value={value})')
    print(f'\n  AC-* PASS/NA: {pass_count}/8')
except Exception as e:
    print(f'  (no se pudo leer verdicts.json: {e})')
"
fi

if [ -f "${E2E_SHORT_OUT}/summary.json" ]; then
    python3 -c "
import json
d = json.load(open('${E2E_SHORT_OUT}/summary.json'))
print(f\"\n  Veredicto global de la ronda: {d.get('overall_verdict','?')}\")
print(f\"  Razón: {d.get('overall_reason','')}\")
" 2>/dev/null || true
fi

echo ""
echo "ADVERTENCIA IMPORTANTE:"
echo "  Este es un smoke test (warmup=2m, baseline=3m, peak=5m, threshold=1500)."
echo "  El veredicto autoritativo del experimento requiere 'make e2e-full'"
echo "  (N=5 rondas con duraciones completas: warmup=5m, baseline=15m, peak=20m,"
echo "   threshold=6000 — aprox. 3.5 h total en CI runner con suficiente RAM)."
echo ""
echo "Reporte HTML: ${E2E_SHORT_OUT}/report.html"
echo ""

exit 0
