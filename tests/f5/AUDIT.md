# Auditoría F5 — Generador de carga estocástico

**Auditor:** `architecture-reviewer` (verificación interna sobre las 2 preguntas obligatorias del spec)
**Artefactos auditados:**
- `load/lib/{sampler,nhpp,mmpp,dirichlet,trace}.js`
- `load/scenarios/{warmup,baseline_asr1,peak_asr2}.js`
- `load/runner/main.js`
- `load/payloads/cdt.js`
- `load/test/{validate_nhpp,integrate_lambda,analyze_mmpp,analyze_dirichlet,measure_payload,repro_hash}.js`
- `load/Dockerfile.k6`
- `infra/k8s/carga/{k6-operator-bootstrap,k6-warmup,k6-baseline,k6-peak,k6-operator-bundle}.yaml`
- `scripts/{load_bootstrap,bundle_k6}.{sh,py}`
- `tests/f5/run-gates.sh`

---

## Pregunta 1 — *¿El generador de carga ataca solo el endpoint del `ApiGateway` (Kong) y NO bypasea hacia `cdt-pais` directamente?*

### Veredicto: **APROBADO**

### Evidencia

**Evidencia 1 — NetworkPolicy `carga-egress-only-borde`** (defensa en profundidad a nivel red):

```yaml
spec:
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: borde
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: observabilidad
```

Egreso permitido SOLO a los namespaces `borde` (donde vive Kong = `ApiGateway`) y `observabilidad` (Prometheus remote-write).
**Cualquier intento de pegar a `linea-verde/cdt-pais.svc`, `acl/acl.svc`, `core-stub/core-stub.svc` o `datos/postgres-*.svc` queda bloqueado por kernel netfilter.**
Verificado por F5.T-10 ✓.

**Evidencia 2 — En código, todas las requests apuntan a `kong-kong-proxy.borde.svc`:**

Único endpoint configurado en los 3 escenarios y el runner:

```js
const KONG_URL = __ENV.KONG_URL || "http://kong-kong-proxy.borde.svc.cluster.local";
http.post(`${data.kongUrl}/v1/cdt`, payload.bodyStr, { headers, ... });
```

No hay ninguna `http.post`/`http.get` que apunte a `cdt-pais.linea-verde.svc`, `acl.acl.svc` o `core-stub.core-stub.svc`. `grep -rn` confirma 0 ocurrencias en `load/` (las únicas menciones a "cdt-pais" son comentarios en `lib/trace.js` documentando el flujo end-to-end Kong → cdt-pais → ACL).

**Evidencia 3 — Smoke runtime:**

Tras el smoke contra el cluster vivo, los logs de Kong proxy capturaron las requests de k6:

```
10.244.0.133 - - "POST /v1/cdt HTTP/1.1" 202 100 "k6/0.53.0"
```

Y los logs de cdt-pais recibieron las requests **vía Kong** (correlation-id propagado). No hay logs de `cdt-pais` recibiendo requests directas.

### Reglas verificadas

- **R4** (ACL es único punto al core) — el generador no se mete en la cadena al core. ✓
- **O2** (CoreBancoZ siempre stub controlado) — k6 no llega al core; va Kong → cdt-pais → ACL → core-stub. ✓

---

## Pregunta 2 — *¿Los escenarios distinguen línea base (ASR-1) y pico (ASR-2) — son dos artefactos separados, no parámetros del mismo?*

### Veredicto: **APROBADO**

### Evidencia

**Evidencia 1 — Archivos JS separados con propósito distinto:**

| Archivo | Modelo estocástico | Propósito |
|---------|-------------------|-----------|
| `load/scenarios/baseline_asr1.js` | λ constante ≈ 0.2 r/s · SIN MMPP · uniforme país | Medir P95 < 800 ms ASR-1 |
| `load/scenarios/peak_asr2.js` | NHPP por tramos · MMPP-2 · Dirichlet(3,1,1) | 6.000 CDT en 20 min ASR-2 |

Verificado por inspección de imports:
- `baseline_asr1.js` **NO** importa `lib/nhpp.js`, `lib/mmpp.js` ni `lib/dirichlet.js`. Solo `lib/sampler.js` para Rng + país uniforme.
- `peak_asr2.js` importa `lib/nhpp.js` (`lambdaAt`, `PEAK_DURATION_S`), `lib/mmpp.js` (`buildMMPP`) y `lib/dirichlet.js` (`buildCountryAssigner`).

**Evidencia 2 — K6 TestRun manifests separados:**

```
infra/k8s/carga/k6-baseline.yaml  (15 min, BASELINE_DURATION=900)
infra/k8s/carga/k6-peak.yaml      (20 min, PEAK_VUS=60, PEAK_MAX_VUS=120)
```

Cada uno apunta a su ConfigMap (`k6-baseline-script` vs `k6-peak-script`) con un bundle JS distinto. No comparten `arguments`, `parallelism`, ni configuración de recursos.

**Evidencia 3 — Make targets independientes:**

```makefile
load-baseline: ## Lanza el K6 TestRun de baseline_asr1 (15 min, 0.2 r/s)
load-peak:     ## Lanza el K6 TestRun de peak_asr2 (20 min, NHPP+MMPP+Dirichlet)
```

No existe ningún `load-run --mode=baseline|peak` o flag conmutador.

**Evidencia 4 — Comentarios documentan la separación intencional:**

`baseline_asr1.js` línea 28:

```js
// **NO** se mezcla con peak_asr2.js — son dos artefactos separados, como exige
// el spec (línea base y pico SEPARADOS, no parámetros del mismo escenario).
```

### Reglas verificadas

- **O1** (subset mínimo viable §3.1) — los 2 escenarios atacan exclusivamente `CDTXPais` (vía Kong + ACL + core-stub), que está en alcance. ✓

---

## Otras reglas verificadas

| # | Regla | Estado |
|---|-------|--------|
| R1 | 8 subsistemas exactos | ✓ — todos los manifests F5 viven en namespace `carga` (subsistema Carga, agregado en F1) |
| R2 | Nombres exactos | ✓ — los manifests no inventan componentes; usan `k6-warmup`, `k6-baseline`, `k6-peak` (artefactos de tooling, no componentes del modelo) |
| R3 | Patrón XPais | ✓ — el generador respeta los 3 países (`pe`/`mx`/`co`) vía header `X-Pais` y Kong enruta |
| R5 | MessageBroker 4 tópicos | (no aplica) — F5 no produce ni consume tópicos, sólo HTTP a Kong |
| R6 | Componentes agnósticos | ✓ — manifests no mencionan "Postgres" ni "Redpanda" en componentes; las refs a "Kong" están solo en infra (donde sí va el producto concreto) |
| R7 | No inventar componentes | ✓ — el `k6-loader` y `k6-operator` son herramientas externas, no componentes del modelo del equipo |
| O3 | Versiones pinneadas | ✓ — `K6_VERSION=v0.53.0` y `K6_OPERATOR_VERSION=0.0.16` en `versions.env`; `Dockerfile.k6` usa `FROM grafana/k6:0.53.0` exacto |
| O4 | Idioma | ✓ — comentarios y docstrings en español; nombres técnicos (Rng, sampleExp, buildMMPP) en inglés |

---

## Veredicto

**APROBADO** — F5 cumple las 2 preguntas críticas del spec y las reglas R1–R7 / O1–O4 del reviewer. 0 hallazgos críticos.

Listo para promoción a F6 (ejecución del experimento y veredicto AC-*).
