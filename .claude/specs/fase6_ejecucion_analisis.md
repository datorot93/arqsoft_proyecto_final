# Fase 6 — Ejecución y análisis

**Agente principal:** `performance-analyst`
**Documento maestro:** `docs/experimento_asr.md` §5, §6.3, §7, §9
**Bloquea a:** F7 (paquete final reproducible)
**Modelo sugerido:** **opus** (interpretación estadística + mapeo a hipótesis arquitectónica requiere razonamiento causal)

## Objetivo

Ejecutar **N=5 rondas** del experimento (cada ronda con seed independiente), capturar evidencia, calcular percentiles autoritativos, **emitir veredicto sobre los 8 criterios AC-1.1..AC-2.6** y mapear cada falla a la hipótesis arquitectónica que refuta (§4.4 del documento maestro).

## Alcance

### Procedimiento de cada ronda (§6.3)

| Etapa | Duración | Carga | Propósito |
|-------|---------|-------|-----------|
| Calentamiento | 5 min | 2 r/s constante | Alinear JIT, llenar pools, descartar cold-start de Postgres. **Métricas descartadas.** |
| Línea base ASR-1 | 15 min | NHPP con λ ≈ 0.22 r/s (≈ 800 req/h) | Registro autoritativo de P95/P99 bajo carga nominal. **Métricas conservadas.** |
| Pico ASR-2 | 20 min | NHPP + MMPP-2 + Dirichlet | Registro autoritativo bajo estrés. **Métricas conservadas.** |

### Cálculo de percentiles (§5.1)

- **Histogramas, no promedios.** Buckets de F3.
- **`histogram_quantile`** sobre ventanas móviles de 1 min (resolución mínima para distinguir efecto MMPP) y agregado sobre la ventana completa para reporte final.
- **Percentiles estratificados:** P95/P99 globales y por dimensión: por país, por pod, por bucket de payload-size, por estado del CB.
- **Coordinated omission:** se asume controlado por F5; el análisis verifica que `arrival_rate` real coincide con `target_rate` en ±2 %.

### Criterios de aceptación (§7) — los 8 a evaluar

| ID | Criterio | Umbral |
|----|---------|--------|
| AC-1.1 | P95 de `http_req_duration` (P1) durante línea base. | < 800 ms en cada ronda. |
| AC-1.2 | P99 durante línea base. | < 1.500 ms en cada ronda (guardrail). |
| AC-2.1 | Volumen completado durante el pico. | ≥ 6.000 aperturas con 202 OK sin contar reintentos. |
| AC-2.2 | `cdt_aperturas_perdidas_total`. | = 0 en cada ronda. |
| AC-2.3 | P95 sostenido durante el pico (por minuto). | < 800 ms en al menos **18 de 20** minutos. |
| AC-2.4 | `broker_dlq_messages_total`. | = 0 en cada ronda. |
| AC-2.5 | Tiempo de escalado HPA (replicas pending → ready). | Documentado y < 60 s en p90. |
| AC-2.6 | CB se recupera correctamente. | Ningún caso CB OPEN > 90 s con core sano. |

### Mapeo falla → hipótesis arquitectónica refutada (§4.4)

| Si falla… | Refuta hipótesis | Pista de rediseño |
|-----------|------------------|-------------------|
| AC-2.1 (volumen) o AC-2.2 (pérdidas) | NHPP con onset abrupto NO se absorbe; HPA o gateway no reaccionan a tiempo. | Revisar `targetCPU` del HPA y burst del rate-limiter de Kong. |
| AC-2.3 (P95 durante pico) en min específicos | MMPP-2 sí degrada: el throttling adaptativo no está convirtiendo bien la ráfaga. | Plugin `rate-limiting-advanced` con sliding window y mejor distribución del burst. |
| AC-1.1 falla solo en un país (estratificado) | Dirichlet expone hot-spotting; recurso global compartido en la ruta crítica. | Auditar que `cdt-pais-pe` no comparte pool/conexión global con los otros países. |
| AC-2.6 (CB no se recupera) | Pareto en core stub satura el CB; los pools del ACL no aíslan. | Aumentar `slidingWindowSize` y revisar bulkhead size. |
| `latency_sla_violation_ratio` alto sin causa clara | Lognormal de payloads agrega varianza patológica al P99. | Revisar serializadores y heap size de los pods de `cdt-pais`. |

### Reporte final

- **Formato:** HTML auto-contenido (gráficos embebidos como SVG/PNG).
- **Por ronda:** veredicto AC-* (`PASS`/`FAIL` por criterio), gráficos P50/P95/P99 minuto-a-minuto, perfil de carga, eventos del HPA y CB.
- **Agregado de N=5 rondas:** P95 medio ± desviación, frecuencia de pase de cada AC-*, lista de hallazgos.
- **Trazabilidad:** cada AC-* fallido enlaza a la hipótesis refutada y a un ticket de rediseño.

## Entradas

- F4 + F5 desplegadas y operativas.
- F3 con dashboards funcionando.
- §7 (criterios) y §4.4 (hipótesis) del documento maestro como fuente normativa.

## Salidas (artefactos)

| Artefacto | Ruta sugerida |
|-----------|---------------|
| Orquestador de rondas (script Python o Bash) | `runs/run_round.py` (ejecuta warmup + baseline + peak con un seed) |
| Captura de métricas (Prometheus snapshots) | `runs/results/<round-id>/prometheus.tar.gz` |
| Manifest de cada ronda (seed, versiones, timestamps) | `runs/results/<round-id>/manifest.json` |
| Generador de reporte HTML | `report/build_report.py` |
| Plantilla de reporte | `report/template.html` (con placeholders Jinja2) |
| Reporte HTML por ronda y agregado | `runs/results/<round-id>/report.html`, `runs/results/aggregate.html` |

## Dependencias técnicas

- Python 3.11+ con `requests`, `pandas`, `matplotlib`, `jinja2`, `scipy.stats` (para tests estadísticos en validación de coordinated omission).
- `promtool` para queries de Prometheus.
- Acceso de lectura a Prometheus, Tempo, Loki desde el host del operador.

## Pasos de implementación (alto nivel)

1. Implementar `run_round.py` que: (a) captura un seed; (b) lanza `warmup` vía k6-operator; (c) tras warmup lanza `baseline_asr1` y captura métricas; (d) tras baseline lanza `peak_asr2`; (e) guarda snapshot de Prometheus.
2. Implementar `aggregate_results.py` que recorre los snapshots de N rondas y calcula percentiles agregados.
3. Implementar evaluadores de cada AC-* como funciones Python independientes (`def evaluate_ac_1_1(metrics) -> Verdict`).
4. Implementar `build_report.py` con plantilla Jinja2; cada AC-* genera un `<section>` con verdict, gráfico y, si falla, link a hipótesis refutada.
5. Validador de coordinated omission: verificar que `arrival_rate` (medida en gateway) coincide con `target_rate` (configurada en k6) dentro de ±2 %; si no, marcar la ronda como **inválida** (no como falla del sistema).
6. Ejecutar 5 rondas piloto con seeds distintos y validar que el script produce reportes idénticos en estructura.

## Criterios de éxito

| ID | Criterio | Cómo verificar |
|----|---------|----------------|
| F6.AC-1 | Cada ronda completa las 3 etapas sin intervención manual. | Log de `run_round.py` muestra las 3 etapas en éxito. |
| F6.AC-2 | Los 8 evaluadores AC-* devuelven `PASS`/`FAIL` con justificación. | Inspección del JSON de resultados: cada AC-* tiene `verdict`, `value`, `threshold`, `reason`. |
| F6.AC-3 | Agregado de N=5 rondas con desviación reportada. | `aggregate.html` muestra `P95 = 612 ± 43 ms` (ejemplo). |
| F6.AC-4 | Trazabilidad falla → hipótesis. | Cualquier AC-* `FAIL` enlaza a la fila correspondiente del mapeo §4.4. |
| F6.AC-5 | Validador de coordinated omission detecta drift. | Forzar un escenario donde k6 cae de 5 r/s a 3 r/s (saturación cliente) y verificar que la ronda se marca `INVALID`. |
| F6.AC-6 | Reporte HTML auto-contenido. | Abrir `report.html` en navegador sin conexión muestra todos los gráficos. |

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|------------|
| Promedio de rondas oculta una ronda patológica | Reportar siempre P95 medio ± desviación + worst-case por ronda. |
| Histograma con buckets gruesos da quantile impreciso | Buckets validados en F3 (bucket exacto a 800 ms). |
| Análisis confunde efecto Dirichlet con problema real | Estratificar siempre por país; nunca reportar solo el agregado. |
| Reporte sin contexto del seed | Manifest incluye seed; reporte lo cita en cada ronda. |

## Pruebas de salida (gate hacia F7)

> **Regla del gate:** TODAS las pruebas `BLOQUEANTE` deben pasar antes de iniciar F7. F7 empaqueta este pipeline como CI nightly — si los veredictos no se generan correctamente en local, no se automatizan.

| ID | Prueba | Comando concreto | Resultado esperado | Gate |
|----|--------|------------------|--------------------|:----:|
| F6.T-1 | 1 ronda completa las 3 etapas | `python runs/run_round.py --seed 42` | exit `0`; log con marcas `warmup_done`, `baseline_done`, `peak_done` | BLOQUEANTE |
| F6.T-2 | 8 evaluadores AC-* responden con verdict | `jq 'keys' runs/results/<id>/verdicts.json` | array con `["AC-1.1","AC-1.2","AC-2.1","AC-2.2","AC-2.3","AC-2.4","AC-2.5","AC-2.6"]` | BLOQUEANTE |
| F6.T-3 | Cada verdict tiene `value`, `threshold`, `reason` | `jq '.[] \| keys' verdicts.json` | todos los entries tienen las 4 keys | BLOQUEANTE |
| F6.T-4 | Coordinated omission detector funciona | inyectar saturación de cliente (cap manual de VUs) y correr | ronda marcada `INVALID` con razón `arrival_rate_drift` | BLOQUEANTE |
| F6.T-5 | Reporte HTML auto-contenido | `ls -la runs/results/<id>/report.html && file report.html` | archivo `> 50 KB`; abrir sin red renderiza gráficos | BLOQUEANTE |
| F6.T-6 | Trazabilidad falla → hipótesis §4.4 | inyectar latencia para forzar `AC-2.3=FAIL` y abrir reporte | sección de hallazgos contiene link explícito a §4.4 con la hipótesis correspondiente | BLOQUEANTE |
| F6.T-7 | Estratificación por país en gráficos | inspección visual del HTML | 3 paneles `pais=pe`, `pais=mx`, `pais=co` por cada métrica de latencia | BLOQUEANTE |
| F6.T-8 | Agregado N=5 con desviación reportada | correr 5 rondas con seeds 42..46 y `python aggregate.py runs/results/*` | `aggregate.html` muestra `P95 = X ± σ ms` | BLOQUEANTE |
| F6.T-9 | Manifest contiene `seed` y `experiment_spec_sha` | `jq '.seed, .experiment_spec_sha' manifest.json` | ambos campos presentes y no `null` | BLOQUEANTE |
| F6.T-10 | Falla atómica: 4/5 PASS no es aprobación | forzar 1 ronda con FAIL artificial | reporte agregado dice `EXPERIMENT FAILED`, no `PARTIAL PASS` | BLOQUEANTE |

**Criterio de promoción a F7:** los 10 tests `BLOQUEANTE` pasan + auditoría aprobada.

## Auditoría requerida al cierre

Invocar `architecture-reviewer`:
1. *"El reporte final reporta cumplimiento contra los 8 AC-* exactos del §7, sin agregar criterios inventados ni omitir ninguno?"*
2. *"Los hallazgos enlazan correctamente a la hipótesis del §4.4 cuando hay falla?"*

## Notas de cierre del experimento

- El experimento se considera **aprobado** solo si en N=5 rondas independientes los 8 AC-* pasan **simultáneamente**.
- Si solo 4 de 5 rondas pasan, **no es aprobación parcial**; se reporta como falla y se documenta la ronda fallida con su seed para reproducción.
- Una ronda inválida (coordinated omission detectado) no cuenta ni a favor ni en contra; se descarta y se reemplaza por una nueva con seed distinto.
