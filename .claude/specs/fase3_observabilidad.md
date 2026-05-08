# Fase 3 — Observabilidad transversal

**Agente principal:** `observability-engineer`
**Documento maestro:** `docs/experimento_asr.md` §5, §6.1, §6.4.7
**Bloquea a:** F4 (instrumentación de servicios), F6 (medición autoritativa)
**Modelo sugerido:** sonnet

## Objetivo

Tener todo el stack de observabilidad **operativo antes** de ejecutar la primera prueba. Sin observabilidad el experimento no produce evidencia y los criterios AC-* no son verificables.

Métricas, trazas y logs deben capturar los **7 puntos de instrumentación** P1–P7 definidos en §5.2 del documento maestro.

## Alcance

### Métricas
- **kube-prometheus-stack 65.x** (Prometheus 2.55, Alertmanager 0.27, Grafana 11.3, node-exporter, kube-state-metrics).
- Retención local: 7 días.
- `ServiceMonitor` por componente: Kong, Redpanda, Postgres (CNPG), Apicurio, k6 (cuando F5 esté lista).
- **Histogramas con buckets fijos** alineados al ASR-1: `[10, 25, 50, 100, 200, 400, 600, 800, 1000, 1500, 2500, 5000, 10000] ms`. El bucket 800 ms es el límite del ASR-1 — no negociable.

### Trazas
- **Grafana Tempo 2.6** como backend.
- **OpenTelemetry Collector 0.110** como pipeline OTLP, modo daemonset, ruteo dual a Tempo (trazas) y Prometheus (exemplars).
- Sampling adaptativo: 100 % en los primeros 30 s de cada corrida (diagnostica el onset), 1 % en estado estable.

### Logs
- **Loki 3.x** + **Promtail** como agente. Logs estructurados JSON.
- Solo se buscan eventos discretos, no logs verbosos: aperturas de CB, retries fallidos, eventos del HPA, cambios de estado del cluster autoscaler.

### Dashboards (provisionados via ConfigMap)
1. **Golden Signals** del `ApiGateway` y de `CDTXPais` (rate, error, duration P50/P95/P99 — RED).
2. **USE** del `AlmacenCDTXPais` (CPU, conexiones DB, IOPS, locks) y del `MessageBroker` (lag, throughput, particiones, DLQ).
3. **Estados del CircuitBreaker** y count de aperturas (Resilience4j metrics).
4. **Cumplimiento ASR** — gráfico que superpone la curva de carga (req/s entrantes) con la curva del P95 minuto-a-minuto y marca visualmente el momento en que P95 cruza 800 ms (si lo cruza).

### Alertas
- `ASR1Violation`: P95 > 800 ms en ventana de 1 min durante línea base.
- `ASR2VolumeShortfall`: throughput < tasa de llegada por más de 30 s consecutivos durante el pico.
- `BrokerDLQNonZero`: cualquier mensaje en DLQ.
- `CBOpenTooLong`: CircuitBreaker en OPEN > 90 s.

## Entradas

- F1 completada (cluster) y F2 completada (componentes a instrumentar ya despliegan `ServiceMonitor` placeholders).
- §5.1 (metodología histogramas) y §6.1.2 (métricas de negocio) del documento maestro.

## Salidas (artefactos)

| Artefacto | Ruta sugerida |
|-----------|---------------|
| Helm values kube-prometheus-stack | `infra/helm/kube-prometheus-stack/values.yaml` |
| Helm values Tempo | `infra/helm/tempo/values.yaml` |
| Helm values Loki + Promtail | `infra/helm/loki/values.yaml` |
| OTel Collector daemonset | `infra/k8s/observabilidad/otel-collector.yaml` |
| Dashboards Grafana (4) | `infra/grafana/dashboards/*.json` |
| Reglas Prometheus + Alertmanager | `infra/k8s/observabilidad/rules/*.yaml` |
| ConfigMap de buckets de histograma | `infra/k8s/observabilidad/histogram-buckets.yaml` (referenciado por F4) |

## Dependencias técnicas

- Operadores instalados en F1.
- Charts de Helm pinneados a versiones del §6.4.10.

## Pasos de implementación (alto nivel)

1. Instalar `kube-prometheus-stack` con valores que: deshabiliten persistent volumes pesados (kind), retención 7d, expongan Grafana en NodePort.
2. Instalar Loki + Promtail con configuración mínima (queries por label, sin alertmanager redundante).
3. Instalar Tempo con backend in-memory (suficiente para corridas locales).
4. Desplegar OTel Collector como daemonset con receivers OTLP/HTTP+OTLP/gRPC, exporters a Tempo y a Prometheus (vía remote-write).
5. Crear `ServiceMonitor`/`PodMonitor` para los componentes desplegados en F2.
6. Provisionar los 4 dashboards Grafana via ConfigMap con label `grafana_dashboard=1`.
7. Crear `PrometheusRule` con las 4 alertas y verificar que Alertmanager las recibe.
8. Definir el ConfigMap de buckets de histograma como **fuente única**: F4 debe leer de aquí los buckets para Micrometer.

## Criterios de éxito

| ID | Criterio | Cómo verificar |
|----|---------|----------------|
| F3.AC-1 | Prometheus scrape exitoso de Kong, Redpanda, Postgres. | `up{job=~"kong|redpanda|postgres-cnpg"} == 1` en todos los targets. |
| F3.AC-2 | Grafana renderiza los 4 dashboards. | `curl -s grafana/api/search?type=dash-db | jq` lista los 4 dashboards. |
| F3.AC-3 | Tempo recibe trazas. | Span de prueba enviado vía `otel-cli` aparece en Tempo en menos de 5 s. |
| F3.AC-4 | Loki ingesta logs JSON. | `logcli query` recupera log de prueba con label `app=test`. |
| F3.AC-5 | Buckets del histograma alineados al ASR. | `curl prometheus/api/v1/series` para una métrica histogram retorna buckets que incluyen `le="800"`. |
| F3.AC-6 | Alerta `ASR1Violation` dispara en simulación. | Inyectar latencia artificial en un pod de prueba y verificar que Alertmanager recibe la alerta en menos de 90 s. |

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|------------|
| Buckets de histograma divergen entre observability y aplicación | ConfigMap único en `observabilidad`, montado como volumen en pods de F4. CI valida hash. |
| Prometheus consume mucha RAM en kind | Retención 7d, scrape interval 30s, drop de métricas cAdvisor no usadas. |
| Trazas saturadas durante el pico | Sampling adaptativo (100% primeros 30s, luego 1%). Configurable por env var. |
| Grafana sin persistencia pierde dashboards | Provisioning declarativo via ConfigMap; los dashboards se recrean en cada `helm upgrade`. |

## Pruebas de salida (gate hacia F4)

> **Regla del gate:** TODAS las pruebas marcadas `BLOQUEANTE` deben pasar antes de iniciar F4 (la instrumentación de servicios depende del ConfigMap `histogram-buckets` y de los `ServiceMonitor` listos).

| ID | Prueba | Comando concreto | Resultado esperado | Gate |
|----|--------|------------------|--------------------|:----:|
| F3.T-1 | Prometheus targets up | `curl -s http://prometheus.observabilidad.svc:9090/api/v1/targets \| jq '[.data.activeTargets[].health] \| group_by(.) \| map({k:.[0],v:length})'` | todos los targets `up` (Kong, Redpanda, Postgres CNPG, Apicurio) | BLOQUEANTE |
| F3.T-2 | 4 dashboards provisionados | `curl -s http://grafana.observabilidad.svc/api/search?type=dash-db \| jq length` | `≥ 4` | BLOQUEANTE |
| F3.T-3 | Tempo recibe trazas | enviar span con `otel-cli` y query `curl -s tempo:3200/api/traces/<traceId>` | retorna span en menos de 5 s | BLOQUEANTE |
| F3.T-4 | Loki recibe logs | `logcli query '{app="test-loki-ingest"}'` después de inyectar log de prueba | retorna ≥ 1 línea | BLOQUEANTE |
| F3.T-5 | Bucket 800 ms presente en Prometheus | `curl -s 'prometheus:9090/api/v1/series?match[]=cdt_open_handler_duration_seconds_bucket' \| jq '.data[] \| select(.le=="0.8")'` | retorna ≥ 1 fila (el bucket umbral del ASR-1 existe) | BLOQUEANTE |
| F3.T-6 | ConfigMap `histogram-buckets` publicado | `kubectl get cm histogram-buckets -n observabilidad -o jsonpath='{.data.buckets\.json}'` | JSON con los 13 buckets de §5.1 | BLOQUEANTE |
| F3.T-7 | OTel Collector daemonset Ready | `kubectl get ds otel-collector -n observabilidad -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}'` | `3/3` (1 por nodo worker) | BLOQUEANTE |
| F3.T-8 | Alerta `ASR1Violation` dispara bajo simulación | inyectar latencia artificial > 800 ms por 90 s y consultar Alertmanager API | alerta con label `alertname=ASR1Violation` en estado `firing` | BLOQUEANTE |
| F3.T-9 | Alerta `BrokerDLQNonZero` dispara | producir 1 mensaje a `cdt.eventos.DLQ` y esperar | alerta `firing` en menos de 60 s | BLOQUEANTE |
| F3.T-10 | Sampling adaptativo configurado | `kubectl exec ... -- /otelcol --components` y revisar config | `tail_sampling` activo con regla de 100 % en primeros 30 s | BLOQUEANTE |

**Criterio de promoción a F4:** los 10 tests `BLOQUEANTE` pasan + auditoría aprobada.

## Auditoría requerida al cierre

Invocar `architecture-reviewer`:
1. *"Los `ServiceMonitor` cubren todos los componentes del subset mínimo viable (§3.1)?"*
2. *"Los 7 puntos de instrumentación P1–P7 (§5.2) están todos cubiertos por algún panel del dashboard?"*
