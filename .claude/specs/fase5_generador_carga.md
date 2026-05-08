# Fase 5 — Generador de carga estocástico

**Agente principal:** `load-test-engineer`
**Documento maestro:** `docs/experimento_asr.md` §4 (entera), §6.4.8
**Bloquea a:** F6 (consume las corridas que produce esta fase)
**Modelo sugerido:** **opus** (modelado estocástico requiere razonamiento matemático no trivial)

## Objetivo

Construir un generador de carga **estocástico, reproducible y libre de coordinated omission** que materialice el modelo de §4 del documento maestro: NHPP + MMPP-2 + Dirichlet + Pareto + Lognormal. Cada corrida debe poder reproducirse exactamente con su `seed`.

## Alcance

### Modelo estocástico (no negociable, ver §4.2 y §4.3)

| Elemento | Distribución / Parámetro | Implementación esperada |
|---------|--------------------------|------------------------|
| Tasa media variable λ(t) | NHPP por fases (tabla §4.2.1): 0–2 min @ 12 r/s; 2–7 min decaimiento 9→6 r/s; 7–15 min 5→3 r/s; 15–20 min 3→2 r/s. | Función JS continua `lambdaAt(tSeconds)` que devuelve la tasa actual. |
| Inter-arrivals | Exponencial(λ(t)) | Inverse-CDF sampling con `seedrandom`. NUNCA aproximaciones por tasa media. |
| Ráfagas | MMPP-2: 15 % del tiempo en `bursty` × 3·λ; durations Exponencial(20s); inter-burst Exponencial(90s). | Máquina de estados de 2 estados con transiciones modeladas. |
| Distribución por país | Dirichlet(α=(3,1,1)) → ~60 % / 25 % / 15 %. | Sample una vez al inicio de la corrida (no por request) para fijar la asimetría. |
| Tamaño payload `SolicitudCDT` | Lognormal(μ=ln(2 KB), σ=0.4) | Random padding del JSON para alcanzar el tamaño. |
| Latencia inyectada en core-stub | Pareto Tipo II (xm=80, α=2.5) | **Implementado en F4 (core-stub)**, no en k6. Pero k6 puede setear header `X-Stub-Latency-Profile` para verificar. |
| Tasa de error core-stub | Bernoulli(p=0.5 % nominal, p=2 % en bursty) | Header `X-Stub-Error-Rate`, valor cambia con el estado MMPP. |
| Think-time (solo línea base ASR-1) | Lognormal(μ=ln(8s), σ=0.6) | No aplica al pico (un cliente = una request en el pico). |

### Tooling

- **k6 v0.53** (open source, Grafana Labs).
- **Executor `ramping-arrival-rate`** — independiza la tasa de llegada de la tasa de respuesta (evita coordinated omission). Locust queda **descartado** por §6.4.8.
- **xk6-distribution** (extensión nativa para distribuciones).
- **xk6-output-prometheus-remote-write** (envío directo a Prometheus durante la corrida).
- **k6-operator 0.0.16** para corridas in-cluster.
- **seedrandom** para reproducibilidad.

### Estructura del repositorio de carga

| Módulo | Responsabilidad |
|--------|----------------|
| `load/lib/nhpp.js` | `lambdaAt(t)` — NHPP por fases. |
| `load/lib/mmpp.js` | Estado `calmo`/`bursty` con transiciones. |
| `load/lib/dirichlet.js` | Sample del vector de pesos por país. |
| `load/lib/sampler.js` | Inverse-CDF y wrapper para todas las distribuciones. |
| `load/scenarios/warmup.js` | 5 min, tasa constante 2 r/s. |
| `load/scenarios/baseline_asr1.js` | 15 min, NHPP con λ ≈ 0.22 r/s (≈ 800 req/h). |
| `load/scenarios/peak_asr2.js` | 20 min, NHPP + MMPP + Dirichlet. **Escenario crítico.** |
| `load/payloads/cdt.js` | Generador de `SolicitudCDT` con tamaño Lognormal. |
| `load/runner/main.js` | Orquesta los 3 escenarios consecutivos por ronda. |

### Reproducibilidad

- Cada ronda recibe un **seed entero de 64 bits**. Todos los samplers se inicializan con derivados deterministas del seed (`seed + offset`).
- Manifest del run incluye: `seed`, `version k6`, `version xk6-distribution`, hash git de `load/`, timestamp de inicio.
- Ejecución idéntica con mismo seed produce mismas inter-arrivals, mismos países, mismos payloads.

### Observabilidad de la propia carga

- k6 emite a Prometheus (vía xk6-output) con labels: `scenario`, `pais`, `seed`, `phase` (warmup/baseline/peak).
- Trace propagation: cada request lleva header `traceparent` con `traceId` derivado del seed + iteration counter (permite buscar request específico en Tempo).

## Entradas

- F4 completada (servicios desplegados y respondiendo en `cdt-pais.linea-verde.svc`).
- F3 completada (Prometheus listo para recibir métricas remote-write de k6).
- §4 del documento maestro (modelo estocástico) — fuente normativa.

## Salidas (artefactos)

| Artefacto | Ruta sugerida |
|-----------|---------------|
| Mono-repo de carga k6 | `load/` (estructura arriba) |
| Imagen Docker de k6 con xk6 extensions | `load/Dockerfile.k6` |
| Manifests `k6-operator` + `K6` CRDs por escenario | `infra/k8s/carga/k6-*.yaml` |
| Validador de NHPP/MMPP | `load/test/validate_nhpp.js` (genera 100k inter-arrivals y verifica con Kolmogorov-Smirnov que es exponencial) |
| Plantilla de manifest de run | `load/runs/template.json` |

## Dependencias técnicas

- **k6 v0.53** binario.
- **xk6** para builds custom.
- Acceso de red desde `carga` namespace hacia `borde` (Kong) — F1 ya provisionó la NetworkPolicy.

## Pasos de implementación (alto nivel)

1. Build de imagen k6 custom con `xk6-distribution` y `xk6-output-prometheus-remote-write` integrados (un solo `docker build`).
2. Implementar `lib/sampler.js` con inverse-CDF para Exponencial, Lognormal, Pareto. Cada función toma una instancia de `seedrandom` para reproducibilidad.
3. Implementar `lib/nhpp.js` con función por tramos según §4.2.1.
4. Implementar `lib/mmpp.js` como máquina de estados; cada tick (resolución 1 s) decide transición de estado.
5. Implementar `lib/dirichlet.js` (Dirichlet via gamma-Marsaglia o aproximación).
6. Escribir los 3 escenarios. Cada uno expone `setup()`, `default()` y `teardown()` con seed inyectado por env.
7. **Test estadístico de validación** (no de carga): generar 10.000 inter-arrivals con λ=5 y verificar con Kolmogorov-Smirnov que es Exponencial(5). El test pasa si p-value > 0.05.
8. Empaquetar como `K6` CRDs para que k6-operator los ejecute.
9. Smoke test contra el cluster: ejecutar `warmup` por 30 s y verificar que las métricas llegan a Prometheus.

## Criterios de éxito

| ID | Criterio | Cómo verificar |
|----|---------|----------------|
| F5.AC-1 | NHPP produce el volumen objetivo del ASR-2. | Integral de λ(t) sobre 20 min ≈ 6.000 ± 200 (rango de tolerancia §4.2.1). |
| F5.AC-2 | Inter-arrivals son Exponencial. | Test KS con p > 0.05 sobre 10.000 muestras. |
| F5.AC-3 | MMPP genera ráfagas según parámetros. | Análisis del log de estados: `bursty` cubre 13–17 % del tiempo, duración media ráfagas ≈ 20 s. |
| F5.AC-4 | Distribución por país en rango. | Sobre 6.000 requests: país 1 = 60 % ± 5 %, país 2 = 25 % ± 4 %, país 3 = 15 % ± 3 %. |
| F5.AC-5 | Mismo seed produce salida idéntica. | Ejecutar 2 corridas con `seed=42`: hashes de los logs de inter-arrivals son iguales. |
| F5.AC-6 | k6 emite métricas a Prometheus. | Query `k6_http_reqs_total{scenario="peak"}` retorna valor > 0 durante la corrida. |
| F5.AC-7 | Trace propagation funciona. | Buscar un `traceId` específico en Tempo y obtener el span completo k6 → Kong → cdt-pais → outbox. |

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|------------|
| Coordinated omission accidental | Documentar uso obligatorio de `ramping-arrival-rate`. CI rechaza scripts con `constant-vus` o `ramping-vus` para los escenarios autoritativos. |
| NHPP por tasa media (incorrecto) | El validador `validate_nhpp.js` corre como pre-commit hook y falla si los inter-arrivals no son exponenciales. |
| Drift entre `core-stub` (Pareto) y k6 (asume Pareto) | El header `X-Stub-Latency-Profile` documenta el contrato; F4 y F5 referencian la misma constante. |
| k6 satura el host antes que el SUT | Máximo de VUs preallocados acotado. Métricas de k6 incluyen `vus_max` para detectar saturación del cliente. |

## Pruebas de salida (gate hacia F6)

> **Regla del gate:** TODAS las pruebas `BLOQUEANTE` deben pasar antes de iniciar F6. F6 confía en que el generador implementa fielmente las distribuciones de §4 — si no, los veredictos son inválidos.

| ID | Prueba | Comando concreto | Resultado esperado | Gate |
|----|--------|------------------|--------------------|:----:|
| F5.T-1 | KS test exponencial sobre 10 000 inter-arrivals | `node load/test/validate_nhpp.js --samples 10000 --lambda 5` | p-value `> 0.05` (no se rechaza H0: Exp) | BLOQUEANTE |
| F5.T-2 | NHPP integral ≈ 6 000 sobre 1 200 s | `node load/test/integrate_lambda.js` | resultado `∈ [5800, 6200]` | BLOQUEANTE |
| F5.T-3 | MMPP-2 — fracción `bursty` correcta | analizar `state_log.json` de 1 corrida | `bursty% ∈ [13, 17]` | BLOQUEANTE |
| F5.T-4 | MMPP-2 — duración media de ráfaga | idem | media `∈ [18, 22] s` | BLOQUEANTE |
| F5.T-5 | Dirichlet — distribución por país | sobre 6 000 requests | `pais1 ∈ [55, 65] %`, `pais2 ∈ [21, 29] %`, `pais3 ∈ [12, 18] %` | BLOQUEANTE |
| F5.T-6 | Reproducibilidad por seed | `k6 run --env SEED=42 ...` × 2 corridas con flag `--out csv=ia.csv` | hash SHA256 de `ia.csv` idéntico entre corridas | BLOQUEANTE |
| F5.T-7 | Lognormal payload size — media correcta | inspeccionar 1 000 requests generados | tamaño promedio `≈ 2 KB ± 10 %` | BLOQUEANTE |
| F5.T-8 | k6 emite a Prometheus durante corrida | `curl 'prometheus:9090/api/v1/query?query=k6_http_reqs_total{scenario="peak"}'` durante el run | valor `> 0` | BLOQUEANTE |
| F5.T-9 | Trace propagation k6 → ACL | enviar request con `traceparent` conocido y query Tempo | trace completo con todos los spans (k6, Kong, cdt-pais, ACL) | BLOQUEANTE |
| F5.T-10 | Generador solo entra por Kong | `kubectl get netpol -n carga -o yaml` | egreso solo permitido a `borde/kong-proxy:8000`; nunca a `linea-verde/cdt-pais` | BLOQUEANTE |
| F5.T-11 | Executor obligatorio `ramping-arrival-rate` | `grep -r "executor" load/scenarios/` | todas las menciones son `ramping-arrival-rate`; ninguna `constant-vus` ni `ramping-vus` | BLOQUEANTE |
| F5.T-12 | Validación pre-commit del modelo | `make validate-load-model` | exit 0 (el script falla si KS no pasa) | BLOQUEANTE |

**Criterio de promoción a F6:** los 12 tests `BLOQUEANTE` pasan + auditoría aprobada.

## Auditoría requerida al cierre

Invocar `architecture-reviewer`:
1. *"El generador de carga ataca solo el endpoint del `ApiGateway` (Kong) y NO bypasea hacia `cdt-pais` directamente?"*
2. *"Los escenarios distinguen línea base (ASR-1) y pico (ASR-2) — son dos artefactos separados, no parámetros del mismo?"*
