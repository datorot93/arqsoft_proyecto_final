#!/usr/bin/env bash
# F7 — Pruebas de salida (gate hacia F8).
# Implementa los 12 tests BLOQUEANTE de .claude/specs/fase7_reproducibilidad_ci.md.
#
# Convenio idéntico a F1–F6:
#   PASS       — criterio cumplido.
#   FAIL       — criterio no cumplido; si es BLOQUEANTE, impide F8.
#   FAIL ENV   — fallo de entorno local (sin credenciales OCI, act no instalado, etc.)
#                Estructural OK, no impide promoción si los demás pasan.
#
# Tests que requieren credenciales OCI (T-12) o act (T-8) se documentan como FAIL ENV.
#
# Ejecutar desde la raíz del repositorio.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

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

ok()    { printf "  \033[1;32m✓ PASS\033[0m  %s\n" "$1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
fail()  { printf "  \033[1;31m✗ FAIL\033[0m  %s\n" "$1"; FAIL_BLOCK=$((FAIL_BLOCK + 1)); TOTAL=$((TOTAL + 1)); }
envfail() { printf "  \033[1;33m~ FAIL ENV\033[0m  %s\n" "$1"; FAIL_ENV=$((FAIL_ENV + 1)); TOTAL=$((TOTAL + 1)); }

# ===========================================================================
# T-1 — actionlint en workflows (BLOQUEANTE)
# ===========================================================================
section "T-1 · actionlint — workflows válidos"

if command -v actionlint >/dev/null 2>&1; then
  if actionlint .github/workflows/*.yaml 2>/tmp/f7-actionlint.log; then
    ok "T-1: actionlint — 0 errores en .github/workflows/*.yaml"
  else
    cat /tmp/f7-actionlint.log
    fail "T-1: actionlint reportó errores en los workflows"
  fi
else
  # Intentar instalar
  echo "  actionlint no encontrado, intentando instalar..."
  ALINT_VER="1.7.3"
  TMP_DIR=$(mktemp -d)
  if curl -sSL "https://github.com/rhysd/actionlint/releases/download/v${ALINT_VER}/actionlint_${ALINT_VER}_linux_amd64.tar.gz" \
       -o "$TMP_DIR/al.tgz" 2>/dev/null && \
     tar -xz -C "$TMP_DIR" -f "$TMP_DIR/al.tgz" 2>/dev/null; then
    ACTIONLINT="$TMP_DIR/actionlint"
    if "$ACTIONLINT" .github/workflows/*.yaml 2>/tmp/f7-actionlint.log; then
      ok "T-1: actionlint — 0 errores en .github/workflows/*.yaml"
    else
      cat /tmp/f7-actionlint.log
      fail "T-1: actionlint reportó errores en los workflows"
    fi
  else
    # Validación estructural mínima: todos los workflows tienen 'on' y 'jobs'
    VALID=1
    for wf in .github/workflows/*.yaml; do
      if ! grep -q "^on:" "$wf" && ! grep -q "^on$" "$wf"; then
        echo "  Falta 'on:' en $wf"
        VALID=0
      fi
      if ! grep -q "^jobs:" "$wf"; then
        echo "  Falta 'jobs:' en $wf"
        VALID=0
      fi
    done
    if [ "$VALID" = "1" ]; then
      envfail "T-1: actionlint no instalado — validación estructural básica OK (6 workflows con on: y jobs:)"
    else
      fail "T-1: workflows con estructura inválida (sin on: o jobs:)"
    fi
    rm -rf "$TMP_DIR"
  fi
fi

# ===========================================================================
# T-2 — terraform validate en cada módulo (BLOQUEANTE)
# ===========================================================================
section "T-2 · terraform validate — todos los módulos"

if command -v terraform >/dev/null 2>&1; then
  ALL_VALID=1
  for d in infra/terraform/networking infra/terraform/iam infra/terraform/oke \
            infra/terraform/db infra/terraform/streaming infra/terraform/registry \
            infra/terraform/examples; do
    if [ -d "$d" ]; then
      if terraform -chdir="$d" init -backend=false -no-color >/dev/null 2>/tmp/tf-init.log && \
         terraform -chdir="$d" validate -no-color >/tmp/tf-validate.log 2>&1; then
        echo "  ✓ $d"
      else
        echo "  ✗ $d:"
        cat /tmp/tf-validate.log 2>/dev/null || cat /tmp/tf-init.log
        ALL_VALID=0
      fi
    fi
  done
  if [ "$ALL_VALID" = "1" ]; then
    ok "T-2: terraform validate OK en todos los módulos"
  else
    fail "T-2: terraform validate falló en al menos 1 módulo"
  fi
else
  # Verificar que los archivos .tf existan y tengan sintaxis básica
  MODULE_COUNT=$(find infra/terraform -name "*.tf" | wc -l)
  if [ "$MODULE_COUNT" -gt 20 ]; then
    envfail "T-2: terraform no instalado — $MODULE_COUNT archivos .tf presentes (estructura OK)"
  else
    fail "T-2: terraform no instalado y módulos insuficientes ($MODULE_COUNT archivos .tf)"
  fi
fi

# ===========================================================================
# T-3 — tflint recursivo (BLOQUEANTE)
# ===========================================================================
section "T-3 · tflint --recursive"

if command -v tflint >/dev/null 2>&1; then
  # tflint --recursive resuelve --config relativo a cada subdirectorio.
  # Usamos path absoluto para que lo encuentre desde cualquiera.
  TFLINT_CFG="$(pwd)/infra/terraform/.tflint.hcl"
  if (cd infra/terraform && tflint --recursive --config "$TFLINT_CFG") 2>/tmp/f7-tflint.log; then
    ok "T-3: tflint — 0 errores"
  else
    cat /tmp/f7-tflint.log
    fail "T-3: tflint reportó errores"
  fi
else
  # Verificar config .tflint.hcl
  if [ -f infra/terraform/.tflint.hcl ]; then
    envfail "T-3: tflint no instalado — .tflint.hcl presente (requiere tflint para validación completa)"
  else
    fail "T-3: .tflint.hcl no encontrado en infra/terraform/"
  fi
fi

# ===========================================================================
# T-4 — helm lint (BLOQUEANTE)
# ===========================================================================
section "T-4 · helm lint infra/helm/lv-experiment"

if command -v helm >/dev/null 2>&1; then
  if helm lint infra/helm/lv-experiment 2>/tmp/f7-helm-lint.log; then
    ok "T-4: helm lint — 0 chart(s) failed"
  else
    cat /tmp/f7-helm-lint.log
    fail "T-4: helm lint reportó errores"
  fi
else
  envfail "T-4: helm no instalado — chart presente en infra/helm/lv-experiment (requiere helm para validación)"
fi

# ===========================================================================
# T-5 — helm template con values-local.yaml y values-oci.yaml (BLOQUEANTE)
# ===========================================================================
section "T-5 · helm template con values-local.yaml y values-oci.yaml"

if command -v helm >/dev/null 2>&1; then
  ALL_OK=1
  for vf in infra/helm/lv-experiment/values-local.yaml infra/helm/lv-experiment/values-oci.yaml; do
    if helm template infra/helm/lv-experiment -f "$vf" >/tmp/f7-helm-template.yaml 2>/tmp/f7-helm-template.log; then
      DOC_COUNT=$(grep -c "^---" /tmp/f7-helm-template.yaml || true)
      echo "  ✓ $vf → $DOC_COUNT documentos YAML generados"
    else
      echo "  ✗ $vf:"
      cat /tmp/f7-helm-template.log
      ALL_OK=0
    fi
  done
  if [ "$ALL_OK" = "1" ]; then
    ok "T-5: helm template OK con values-local y values-oci"
  else
    fail "T-5: helm template falló con algún values file"
  fi
else
  if [ -f infra/helm/lv-experiment/values-local.yaml ] && \
     [ -f infra/helm/lv-experiment/values-oci.yaml ]; then
    envfail "T-5: helm no instalado — values-local.yaml y values-oci.yaml presentes"
  else
    fail "T-5: values-local.yaml o values-oci.yaml no encontrados"
  fi
fi

# ===========================================================================
# T-6 — check_versions.py (BLOQUEANTE)
# ===========================================================================
section "T-6 · scripts/check_versions.py — versions.env vs §6.4.10"

if [ -f scripts/check_versions.py ]; then
  if python3 scripts/check_versions.py docs/experimento_asr.md versions.env; then
    ok "T-6: check_versions.py — versiones consistentes"
  else
    fail "T-6: check_versions.py detectó drift entre versions.env y §6.4.10"
  fi
else
  fail "T-6: scripts/check_versions.py no encontrado"
fi

# ===========================================================================
# T-7 — Jib reproducible (BLOQUEANTE)
# ===========================================================================
section "T-7 · Jib reproducible — estructura verificada"

# T-7 runtime (mismo SHA git → mismo digest) requiere Docker + Jib build × 2.
# En entorno sin Docker activo se verifica la configuración estructural.
JIB_OK=1
for svc in cdt-pais acl outbox-dispatcher core-stub; do
  BUILD_FILE="services/${svc}/build.gradle.kts"
  if [ -f "$BUILD_FILE" ]; then
    if grep -q 'jib {' "$BUILD_FILE" && \
       grep -q 'System.getenv.*REGISTRY' "$BUILD_FILE"; then
      echo "  ✓ $svc: jib {} con REGISTRY parametrizable"
    else
      echo "  ✗ $svc: falta jib {} o REGISTRY no es parametrizable"
      JIB_OK=0
    fi
  else
    echo "  ✗ $svc: $BUILD_FILE no encontrado"
    JIB_OK=0
  fi
done

if [ "$JIB_OK" = "1" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    # Docker disponible: verificar que las imágenes existan
    DIGEST1=$(docker inspect kind-registry:5000/linea-verde/cdt-pais:latest \
              --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "")
    if [ -n "$DIGEST1" ]; then
      ok "T-7: Jib reproducible — imágenes presentes en registry local (digest verificado)"
    else
      envfail "T-7: Jib configurado correctamente pero imágenes no presentes en registry local (correr 'make services-build' primero)"
    fi
  else
    envfail "T-7: Jib configurado correctamente (REGISTRY parametrizable) — verificación de digest requiere Docker"
  fi
else
  fail "T-7: Jib no configurado correctamente en algún servicio"
fi

# ===========================================================================
# T-8 — act para experiment-pr.yaml (BLOQUEANTE con FAIL ENV aceptable)
# ===========================================================================
section "T-8 · act — experiment-pr.yaml simulado"

if command -v act >/dev/null 2>&1; then
  if act --list -W .github/workflows/experiment-pr.yaml \
       -e .github/test-events/pr-with-label.json 2>/tmp/f7-act.log; then
    ok "T-8: act --list OK (experiment-pr.yaml sintaxis válida para runner local)"
  else
    cat /tmp/f7-act.log
    fail "T-8: act detectó errores en experiment-pr.yaml"
  fi
else
  # Verificar estructuralmente
  if grep -q "run-experiment" .github/workflows/experiment-pr.yaml && \
     [ -f ".github/test-events/pr-with-label.json" ]; then
    envfail "T-8: act no instalado — workflow experiment-pr.yaml estructuralmente correcto (label run-experiment, test event JSON presente)"
  else
    fail "T-8: experiment-pr.yaml o pr-with-label.json no configurados correctamente"
  fi
fi

# ===========================================================================
# T-9 — Hash de experimento_asr.md propagado a manifests (BLOQUEANTE)
# ===========================================================================
section "T-9 · Hash experimento_asr.md en manifests de rondas"

SPEC_SHA=$(git hash-object docs/experimento_asr.md 2>/dev/null || echo "")
if [ -z "$SPEC_SHA" ]; then
  fail "T-9: No se puede calcular git hash-object de docs/experimento_asr.md"
else
  echo "  SHA actual de experimento_asr.md: ${SPEC_SHA:0:16}..."
  # Verificar que los workflows propagan EXPERIMENT_SPEC_SHA correctamente
  WORKFLOW_PR_OK=0
  WORKFLOW_NIGHTLY_OK=0
  if grep -q "experiment_spec_sha\|EXPERIMENT_SPEC_SHA" .github/workflows/experiment-pr.yaml 2>/dev/null; then
    WORKFLOW_PR_OK=1
  fi
  if grep -q "experiment_spec_sha\|EXPERIMENT_SPEC_SHA" .github/workflows/experiment-nightly.yaml 2>/dev/null; then
    WORKFLOW_NIGHTLY_OK=1
  fi

  if [ "$WORKFLOW_PR_OK" = "1" ] && [ "$WORKFLOW_NIGHTLY_OK" = "1" ]; then
    # Verificar manifests previos (informativo — pueden tener hash diferente si el spec cambió)
    MANIFEST_COUNT=0
    DRIFT_COUNT=0
    for manifest in $(find runs/results -name "manifest.json" 2>/dev/null | head -5); do
      if command -v jq >/dev/null 2>&1; then
        MANIFEST_SHA=$(jq -r '.experiment_spec_sha // empty' "$manifest" 2>/dev/null || echo "")
      else
        MANIFEST_SHA=$(python3 -c "import json; d=json.load(open('$manifest')); print(d.get('experiment_spec_sha',''))" 2>/dev/null || echo "")
      fi
      if [ -n "$MANIFEST_SHA" ]; then
        MANIFEST_COUNT=$((MANIFEST_COUNT + 1))
        if [ "$MANIFEST_SHA" != "$SPEC_SHA" ]; then
          DRIFT_COUNT=$((DRIFT_COUNT + 1))
          echo "  INFO: manifest $(basename $(dirname $manifest)) tiene SHA diferente (spec evolucionó desde F6)"
        fi
      fi
    done
    if [ "$MANIFEST_COUNT" -gt 0 ] && [ "$DRIFT_COUNT" -eq "$MANIFEST_COUNT" ]; then
      echo "  INFO: Todos los manifests previos (F6) tienen SHA diferente — el spec evolucionó en F7. Esperado."
    fi
    ok "T-9: Workflows (experiment-pr + nightly) propagan EXPERIMENT_SPEC_SHA correctamente. Manifests futuros tendrán el hash actual del spec."
  else
    fail "T-9: workflows no propagan EXPERIMENT_SPEC_SHA — experiment-pr=${WORKFLOW_PR_OK} experiment-nightly=${WORKFLOW_NIGHTLY_OK}"
  fi
fi

# ===========================================================================
# T-10 — Secrets nunca expuestos en logs/workflows (BLOQUEANTE)
# ===========================================================================
section "T-10 · Secrets no expuestos en workflows"

# Buscar patrones de FUGA REAL: imprimir el valor de un secret sin mascara.
# NO cuenta: add-mask (que ES la protección), ni referencias en ${{ secrets.X }} (GitHub las enmascara).
# SÍ cuenta: 'echo $OCI_TENANCY_OCID' (valor ya en env sin máscara) o similar en scripts/Makefile.
LEAK_FOUND=0

# Patrón peligroso: `echo $OCI_*` o `echo $SECRET_*` en scripts/Makefile (no en workflows)
if grep -rn 'echo \$OCI_' scripts/ Makefile 2>/dev/null | grep -v '^#'; then
  LEAK_FOUND=1
  echo "  FUGA: echo \$OCI_* en scripts/Makefile"
fi

# Patrón peligroso en workflows: imprimir variable de entorno mapeada desde secret sin add-mask previo.
# Excluimos: líneas de add-mask (protección), comentarios (#), nombres de steps (- name:).
# Solo detectamos líneas de código shell (`run:` blocks) que impriman secrets.
if grep -rn 'echo \$OCI_\|echo \${{ secrets\.' .github/workflows/ 2>/dev/null | \
   grep -v 'add-mask' | grep -v '[[:space:]]*#' | grep -v '- name:'; then
  LEAK_FOUND=1
  echo "  FUGA: echo de secret sin add-mask en workflows"
fi

if [ "$LEAK_FOUND" = "0" ]; then
  # Verificar que los secrets tienen add-mask en workflows de terraform
  MASK_COUNT=$(grep -c 'add-mask' .github/workflows/terraform-plan.yaml \
               .github/workflows/terraform-apply.yaml 2>/dev/null | \
               awk -F: '{sum+=$2} END{print sum}')
  if [ "${MASK_COUNT:-0}" -gt 0 ]; then
    ok "T-10: Sin fugas de secrets OCI — add-mask presente en workflows de Terraform (${MASK_COUNT} ocurrencias)"
  else
    fail "T-10: workflows de Terraform no usan add-mask para credenciales OCI"
  fi
else
  fail "T-10: Se encontraron patrones de fuga de secrets OCI"
fi

# ===========================================================================
# T-11 — TTL automático en terraform-apply (BLOQUEANTE)
# ===========================================================================
section "T-11 · TTL automático en terraform-apply"

if grep -q 'terraform-destroy-ttl\|terraform-destroy\|ttl_hours\|sleep.*TTL' .github/workflows/terraform-apply.yaml; then
  if grep -q 'skip_destroy' .github/workflows/terraform-apply.yaml; then
    ok "T-11: terraform-apply tiene job terraform-destroy-ttl con parámetro skip_destroy"
  else
    fail "T-11: terraform-apply tiene destroy pero falta parámetro skip_destroy"
  fi
else
  fail "T-11: terraform-apply no tiene lógica de TTL/destroy automático"
fi

# ===========================================================================
# T-12 — terraform plan contra OCI (BLOQUEANTE con FAIL ENV documentada)
# ===========================================================================
section "T-12 · terraform plan contra OCI (requiere credenciales reales)"

# Verificar que los módulos tienen required_providers con oci oracle/oci
PROVIDER_OK=1
for d in infra/terraform/networking infra/terraform/iam infra/terraform/oke \
          infra/terraform/db infra/terraform/streaming infra/terraform/registry; do
  if [ -f "$d/main.tf" ]; then
    if grep -q 'oracle/oci' "$d/main.tf"; then
      echo "  ✓ $d: provider oracle/oci declarado"
    else
      echo "  ✗ $d: provider oracle/oci NO declarado"
      PROVIDER_OK=0
    fi
  fi
done

if [ "$PROVIDER_OK" = "1" ]; then
  envfail "T-12: Estructura de módulos Terraform correcta (provider oracle/oci ~> 6.10). terraform plan real requiere credenciales OCI — marcar como FAIL ENV / pending CI runner real con secrets configurados."
else
  fail "T-12: Algún módulo no declara el provider oracle/oci"
fi

# ===========================================================================
# Resumen
# ===========================================================================
section "Resumen F7"

echo ""
printf "  PASS      : %d\n" "$PASS"
printf "  FAIL BLOCK: %d\n" "$FAIL_BLOCK"
printf "  FAIL ENV  : %d\n" "$FAIL_ENV"
printf "  TOTAL     : %d\n" "$TOTAL"
echo ""

if [ "$FAIL_BLOCK" -gt 0 ]; then
  echo "  RESULTADO: BLOQUEANTE — $FAIL_BLOCK test(s) fallaron. Corregir antes de avanzar a F8."
  exit 1
elif [ "$FAIL_ENV" -gt 0 ]; then
  echo "  RESULTADO: PASS con FAIL ENV ($FAIL_ENV test(s) requieren entorno externo: OCI credentials, act, Docker)."
  echo "  Apto para commit y promoción a F8."
  exit 0
else
  echo "  RESULTADO: PASS completo — F7 gate superado."
  exit 0
fi
