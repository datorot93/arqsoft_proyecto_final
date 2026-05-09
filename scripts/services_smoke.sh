#!/usr/bin/env bash
# F4 — Smoke test end-to-end de los 3 países.
# Verifica que POST /v1/cdt retorna 202 con cdtId UUID para pe, mx, co.
#
# Prerrequisitos:
#   - services_deploy.sh ejecutado y todos los pods Running.
#   - Kong proxy accesible en localhost:80 (NodePort o port-forward).
#
# Para port-forward: kubectl port-forward -n borde svc/kong-proxy 8000:80 &

set -euo pipefail

KONG_HOST="${KONG_HOST:-localhost}"
KONG_PORT="${KONG_PORT:-80}"
KONG_URL="http://${KONG_HOST}:${KONG_PORT}"

PASS=0
FAIL=0

smoke_test() {
  local pais="$1"
  local payload='{"clienteId":"smoke-001","monto":1000.00,"plazoDias":90,"tasaAnual":0.0850}'

  echo ""
  echo "--- Smoke test: país=$pais ---"
  echo "    POST ${KONG_URL}/v1/cdt"

  HTTP_CODE=$(curl -s -o /tmp/smoke_response_${pais}.json -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Pais: ${pais}" \
    -d "$payload" \
    "${KONG_URL}/v1/cdt" 2>/dev/null || echo "000")

  BODY=$(cat /tmp/smoke_response_${pais}.json 2>/dev/null || echo "{}")

  if [ "$HTTP_CODE" = "202" ]; then
    CDT_ID=$(echo "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cdtId',''))" 2>/dev/null || echo "")
    if [ -n "$CDT_ID" ] && echo "$CDT_ID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
      echo "    HTTP 202 - cdtId=$CDT_ID  [UUID v4 valido]"
      echo "    OK: pais=$pais PASS"
      PASS=$((PASS + 1))
    else
      echo "    HTTP 202 pero cdtId inválido o ausente: $BODY"
      echo "    FAIL: pais=$pais"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "    HTTP $HTTP_CODE (esperado 202)"
    echo "    Respuesta: $BODY"
    echo "    FAIL: pais=$pais"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== F4: Smoke test de apertura de CDT (3 países) ==="
echo "    Kong URL: $KONG_URL"

for pais in pe mx co; do
  smoke_test "$pais"
done

echo ""
echo "=== Resultado del smoke test ==="
echo "    PASS: $PASS/3"
echo "    FAIL: $FAIL/3"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "FAIL: $FAIL país(es) fallaron. Revisar logs:"
  echo "    kubectl logs -n linea-verde -l app.kubernetes.io/name=cdt-pais --tail=50"
  exit 1
else
  echo ""
  echo "OK: todos los países respondieron 202 con UUID v4 válido."
fi
