# load/ — Generador de carga estocástico

**Fase F5** del experimento ASR-1/ASR-2 — Banco Z Línea Verde.
Documentación completa: `.claude/specs/fase5_generador_carga.md`, `docs/experimento_asr.md` §4.

## Arquitectura

| Módulo | Responsabilidad |
|--------|----------------|
| `lib/sampler.js` | PRNG `Mulberry32` + inverse-CDF (Exp, Lognormal, Gamma, Bernoulli, Pareto). |
| `lib/nhpp.js` | NHPP por tramos lineales — `lambdaAt(t)`, integral analítica, thinning. |
| `lib/mmpp.js` | MMPP-2 (`calmo`/`bursty`) con transiciones Exp(media=20s/90s). |
| `lib/dirichlet.js` | Dirichlet(α=(3,1,1)) — sample una vez por run, asignación categórica. |
| `lib/trace.js` | W3C traceparent determinista del (seed, iter). |
| `payloads/cdt.js` | Solicitud CDT con tamaño Lognormal(ln(2048), 0.4), cap 8 KB. |
| `scenarios/warmup.js` | 5 min · 2 r/s · `ramping-arrival-rate`. |
| `scenarios/baseline_asr1.js` | 15 min · 0.2 r/s · `ramping-arrival-rate`. ASR-1. |
| `scenarios/peak_asr2.js` | 20 min · NHPP + MMPP + Dirichlet · `ramping-arrival-rate`. ASR-2. |
| `runner/main.js` | Orquesta los 3 escenarios consecutivos en una sola corrida k6. |
| `test/*.js` | Validadores Node-standalone (sin k6 runtime). |

## Reproducibilidad

- PRNG: `Mulberry32` seed-determinista.  Mismo `SEED` -> misma secuencia
  byte-a-byte de inter-arrivals, países y payloads.
- Sub-streams: `seedFor(rootSeed, label)` deriva sub-seeds independientes
  para NHPP, MMPP, Dirichlet, payload — sin interferencia entre samplers.
- F5.T-6 verifica que `node test/repro_hash.js --seed 42` retorna el mismo
  SHA-256 entre invocaciones.

## Uso

### Tests JS standalone (no requieren k6 ni cluster)

```bash
cd load
node test/validate_nhpp.js --samples 10000 --lambda 5   # KS
node test/integrate_lambda.js                            # ∫λ(t) dt
node test/analyze_mmpp.js                                # bursty %
node test/analyze_dirichlet.js                           # país %
node test/measure_payload.js                             # payload size
node test/repro_hash.js --seed 42                        # reproducibilidad
```

### Smoke test runtime (requiere k6 binario instalado)

```bash
# warmup 30 s contra Kong:
SEED=42 KONG_URL=http://localhost:8000 \
  k6 run scenarios/warmup.js --duration 30s
```

### En cluster (vía k6-operator)

```bash
make load-build      # build de la imagen + kind load
make load-deploy     # k6-operator + manifests
make load-warmup     # lanza el K6 CR de warmup
make load-baseline
make load-peak
make test-f5         # gate
```

## Limitaciones conocidas

- **Pareto en el cliente:** NO se modela en k6.  El core-stub (F4) implementa
  Pareto Tipo II.  k6 envía `X-Stub-Latency-Profile: pareto` para hacer
  explícito el contrato.
- **Errores Bernoulli en bursty:** k6 no tiene visibilidad del estado MMPP
  dentro de `default()` (los stages vienen pre-computados).  Enviamos 0.5%
  nominal; si F6 requiere la asimetría error rate por estado, se puede
  pre-calcular con tags.
- **Dirichlet draw varianza:** un solo draw puede caer fuera del rango
  empírico esperado (60/25/15) por la varianza inherente.  El test
  `analyze_dirichlet.js` documenta el draw exacto.
