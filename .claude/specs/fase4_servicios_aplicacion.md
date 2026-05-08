# Fase 4 — Servicios de aplicación (Spring Boot)

**Agente principal:** `spring-boot-developer`
**Documento maestro:** `docs/experimento_asr.md` §3.1, §5.2, §6.4.1, §6.4.2
**Bloquea a:** F5 (genera carga contra estos servicios), F6 (mide su comportamiento)
**Modelo sugerido:** sonnet

## Objetivo

Implementar los **4 servicios de aplicación** del subset mínimo viable, con la instrumentación necesaria para que F6 mida P95/P99 y los criterios AC-* en los puntos P1–P7 de §5.2.

## Alcance

### Servicios a implementar

| Servicio | Rol | Notas |
|----------|-----|-------|
| `cdt-pais` | Implementa el componente `CDTXPais`. **Una imagen, 3 deployments** (uno por país: `pe`, `mx`, `co`). El país se configura por env var `LV_PAIS` y se persiste como atributo en cada CDT. | Spring Boot 3.3 + virtual threads. Endpoint `POST /v1/cdt`. |
| `acl` | Implementa el subsistema `Integracion` (`AdaptadorCore` + `CircuitBreaker`). Único punto de salida hacia el core stub. | Resilience4j 2.2 (CircuitBreaker, Bulkhead, Retry con jitter). Pool HikariCP no aplica (no toca DB), pero pool de conexiones HTTP acotado con `maximumConnections=20`. |
| `outbox-dispatcher` | Lee la tabla `outbox_cdt_eventos` y publica al broker. **1 réplica** (no se prueba elasticidad aquí). | Spring Boot. Polling cada 200 ms. Publica a `cdt.eventos`. Marca `published_at` tras ack del broker. |
| `core-stub` | Reemplaza `CoreBancoZ`. Inyecta latencia con distribución **Pareto Tipo II** y errores con **Bernoulli**. | Spring Boot WebFlux + Apache Commons Math 3.6 para distribuciones. Configurable por header de la request o env var. |

### Stack técnico (no negociable, ver §6.4.1, §6.4.2)

- **Java 21 LTS** (Eclipse Temurin), **virtual threads** vía `spring.threads.virtual.enabled=true`.
- **Spring Boot 3.3.x** + Spring Web (servlet stack) + Spring Data JDBC + HikariCP 5.x.
- **Resilience4j 2.2.x**.
- **Spring Kafka 3.2.x** (Kafka client 3.7).
- **Micrometer 1.13.x** + `micrometer-registry-prometheus`. Buckets de histograma leídos desde el ConfigMap publicado por F3.
- **OpenTelemetry Java agent 2.x** como sidecar/init-container que inyecta el agent (no se compila contra el SDK; auto-instrumentación HTTP/JDBC/Kafka).
- **Apache Commons Math 3.6.x** (solo en `core-stub`).
- Build: **Gradle 8.10 Kotlin DSL** + **Jib 3.4** (sin Dockerfile).
- Imagen base: `eclipse-temurin:21-jre-jammy`.

### Patrón de apertura de CDT (lo que valida ASR-1)

Endpoint `POST /v1/cdt` en `cdt-pais`:

1. Validación mínima de payload (sin llamada a KYC; clientes asumidos onboarded — §3.2).
2. **Una sola transacción ACID** que `INSERT INTO cdt.cdt` + `INSERT INTO cdt.outbox_cdt_eventos`.
3. Retorna **`202 Accepted`** con `cdtId`.
4. Latencia objetivo: **< 800 ms en P95** (ASR-1).
5. La publicación al broker la hace `outbox-dispatcher` de forma asíncrona — **no** afecta la latencia del 202.

### Integración con F2 y F3

- DB: cada deployment de `cdt-pais` apunta al cluster Postgres del país correspondiente. Conexión vía secrets de CNPG.
- Broker: `outbox-dispatcher` y consumer del `acl` (en otra ronda; este experimento no consume `cdt.eventos` en el critical path) configuran `bootstrap.servers` apuntando a Redpanda.
- Métricas: cada servicio expone `/actuator/prometheus`. ServiceMonitors definidos en F3 ya están listos.
- Trazas: OTel agent propaga `traceparent` desde k6 (F5) hasta el ACL.
- HPA v2: `cdt-pais` con target CPU 60 %, `min=2`, `max=20`. `acl` y `outbox-dispatcher` sin HPA (replica fija).

## Entradas

- F2 completada (Postgres y Redpanda corriendo).
- F3 completada (ConfigMap de buckets, ServiceMonitors esperando endpoints).
- §5.2 (puntos de instrumentación P3, P4, P5, P6 deben ser implementados aquí).

## Salidas (artefactos)

| Artefacto | Ruta sugerida |
|-----------|---------------|
| Mono-repo Gradle multi-proyecto | `services/` con módulos `cdt-pais`, `acl`, `outbox-dispatcher`, `core-stub`, `commons` |
| Imágenes OCI vía Jib | publicadas a registry local de kind |
| Manifests K8s `Deployment`/`Service`/`HPA` | `infra/k8s/linea-verde/`, `infra/k8s/acl/`, `infra/k8s/core-stub/` |
| Helm chart paramétrico (opcional pero recomendado) | `infra/helm/services/` con `Values.yaml` para `pais`, `replicas`, `image.tag` |
| Tests unitarios de las distribuciones del stub | `services/core-stub/src/test/java/...` |
| `Makefile` targets `services-build`, `services-deploy` | `Makefile` |

## Dependencias técnicas

Ver §6.4.1 y §6.4.2 del documento maestro. Versiones críticas: Spring Boot 3.3.x, Resilience4j 2.2.x, Java 21 LTS.

## Pasos de implementación (alto nivel)

1. Bootstrapping Gradle multi-proyecto con `commons` (entidades, eventos, configuración compartida).
2. `cdt-pais`: controller + service + repository (Spring Data JDBC), bean de `MeterRegistry` con buckets del ConfigMap, configuración HikariCP `maximumPoolSize=20`.
3. `acl`: client HTTP a `core-stub` con Resilience4j (CB threshold 50 % de fallas en window de 20 reqs, sliding window count-based, half-open con 3 reqs de prueba). Bulkhead de 20 hilos.
4. `outbox-dispatcher`: scheduler con `@Scheduled(fixedDelay=200)`, query con `FOR UPDATE SKIP LOCKED` para concurrencia segura, marca `published_at` post-ack.
5. `core-stub`: endpoint `POST /core/reservar`, sampler Pareto (xm=80, α=2.5) → `Thread.sleep(latencia)`. Bernoulli p configurable por header `X-Stub-Error-Rate`.
6. Build con Jib y publicar al registry de kind. Labels: `app.kubernetes.io/component=...`, `pais=...`.
7. Manifests K8s: deployments (3 de `cdt-pais` + 1 de `acl` + 1 de `outbox-dispatcher` por país × 1 + 1 de `core-stub`), HPA v2 para `cdt-pais`.
8. Smoke test: `curl POST /v1/cdt` → 202 Accepted. Verificar fila en Postgres y mensaje en `cdt.eventos`.

## Criterios de éxito

| ID | Criterio | Cómo verificar |
|----|---------|----------------|
| F4.AC-1 | `POST /v1/cdt` retorna 202 con `cdtId` válido. | Smoke test en cada país; UUID v4 en respuesta. |
| F4.AC-2 | INSERT en `cdt` y `outbox` ocurren en la misma transacción. | Test de integración: forzar fallo post-INSERT; ambas filas ausentes. |
| F4.AC-3 | Latencia del 202 (sin carga) < 200 ms. | `curl -w "%{time_total}"` repetido 100 veces. |
| F4.AC-4 | `outbox-dispatcher` publica eventos en `cdt.eventos`. | `rpk topic consume cdt.eventos --num 10` retorna eventos con `cdtId` esperado. |
| F4.AC-5 | CircuitBreaker abre cuando `core-stub` retorna 50 % de errores. | Forzar `X-Stub-Error-Rate=0.6` por 30 s y observar métrica `resilience4j_circuitbreaker_state{state="open"}`. |
| F4.AC-6 | HPA v2 escala `cdt-pais` bajo carga sintética. | `kubectl get hpa cdt-pais-pe -w` muestra `replicas` creciente bajo carga. |
| F4.AC-7 | Buckets de histograma coinciden con F3. | `histogram_quantile` de Prometheus retorna valor coherente; bucket `le="800"` presente. |

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|------------|
| Virtual threads con JDBC bloqueante producen pin a carrier thread | HikariCP 5+ libera pinning; verificar con `-Djdk.virtualThreadScheduler.parallelism` y `-Djdk.tracePinnedThreads=full` en pruebas. |
| Outbox dispatcher se queda en `lock` con muchos eventos | `FOR UPDATE SKIP LOCKED` + commit por batch de 100 eventos. |
| Auto-instrumentation OTel agrega overhead en P99 | Medir con y sin agent en línea base; ajustar sampling si overhead > 5 %. |
| Drift entre paises (e.g., `cdt-pais-pe` con código distinto) | **Una sola imagen** parametrizada por env var `LV_PAIS`. Prohibido tener variantes por país. |

## Pruebas de salida (gate hacia F5)

> **Regla del gate:** TODAS las pruebas `BLOQUEANTE` deben pasar antes de iniciar F5. F5 genera carga contra estos servicios — si los servicios no responden correctamente, la carga produce datos basura.

| ID | Prueba | Comando concreto | Resultado esperado | Gate |
|----|--------|------------------|--------------------|:----:|
| F4.T-1 | `POST /v1/cdt` retorna 202 con `cdtId` | `curl -X POST -H "Content-Type: application/json" -H "X-Pais: pe" -d @sample-cdt.json http://kong-proxy.borde.svc:8000/v1/cdt` | HTTP `202`, body `{"cdtId":"<UUID v4>"}` | BLOQUEANTE |
| F4.T-2 | Fila persistida en Postgres del país correcto | `kubectl exec -n datos postgres-pe-1 -- psql -U postgres -t -c "SELECT count(*) FROM cdt.cdt WHERE id='<UUID>';"` | `1` | BLOQUEANTE |
| F4.T-3 | Fila en outbox con la misma transacción | `psql -t -c "SELECT count(*) FROM cdt.outbox_cdt_eventos WHERE cdt_id='<UUID>';"` | `1` | BLOQUEANTE |
| F4.T-4 | Evento publicado en `cdt.eventos` | `rpk topic consume cdt.eventos --num 100 \| grep <UUID>` | mensaje encontrado en menos de 10 s después del 202 | BLOQUEANTE |
| F4.T-5 | Latencia 202 sin carga < 200 ms (P95 de 100 muestras) | `for i in {1..100}; do curl -w "%{time_total}\n" -o /dev/null -s -X POST .../v1/cdt; done \| sort -n \| awk 'NR==95'` | `< 0.20` | BLOQUEANTE |
| F4.T-6 | Transaccionalidad outbox: rollback si falla post-INSERT | test de integración con punto de inyección de fallo entre INSERT cdt y INSERT outbox | ambas filas ausentes (rollback completo) | BLOQUEANTE |
| F4.T-7 | CB abre con error rate 60 % en core-stub | curl con `X-Stub-Error-Rate: 0.6` por 30 s y consultar `resilience4j_circuitbreaker_state{state="open"}` | métrica = `1` durante el periodo | BLOQUEANTE |
| F4.T-8 | CB se recupera tras quitar carga | quitar `X-Stub-Error-Rate` y esperar | `state="closed"=1` en menos de 60 s | BLOQUEANTE |
| F4.T-9 | HPA escala bajo carga | `wrk -t4 -c100 -d2m http://kong-proxy.../v1/cdt` y `kubectl get hpa cdt-pais-pe -w` | `replicas` crecen de `2` a `>2` antes de 90 s | BLOQUEANTE |
| F4.T-10 | Histogram con bucket 800 ms expuesto | `curl http://cdt-pais-pe.linea-verde.svc:8080/actuator/prometheus \| grep 'cdt_open_handler_duration_seconds_bucket{.*le="0.8"'` | retorna ≥ 1 línea | BLOQUEANTE |
| F4.T-11 | No hay pinning de virtual threads | corrida con `-Djdk.tracePinnedThreads=full` y revisar logs durante 5 min de carga | log limpio (sin `Thread "...": pinned`) | BLOQUEANTE |
| F4.T-12 | Una sola imagen multi-país | `crane digest <img>:latest-pe` vs `crane digest <img>:latest-mx` | digests idénticos (parametrización por env, no por build) | BLOQUEANTE |
| F4.T-13 | ACL es único punto al core | `kubectl get netpol -n linea-verde -o yaml \| grep -A5 egress \| grep core-stub` | sin coincidencias (egreso a core solo desde `acl`) | BLOQUEANTE |

**Criterio de promoción a F5:** los 13 tests `BLOQUEANTE` pasan + auditoría aprobada.

## Auditoría requerida al cierre

Invocar `architecture-reviewer`:
1. *"`cdt-pais` corresponde al componente `CDTXPais` del modelo? El sufijo XPais se preserva como instancia (no como clase distinta)?"*
2. *"`acl` implementa fielmente el subsistema `Integracion` (`AdaptadorCore` + `CircuitBreaker`)? Hay ruta directa de `cdt-pais` al `core-stub` que salta el ACL?"*
3. *"El componente `outbox-dispatcher` no aparece en `componentes.jpeg` — está justificado como detalle de implementación del patrón Outbox y no como componente arquitectónico nuevo?"*
