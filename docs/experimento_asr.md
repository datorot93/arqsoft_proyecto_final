# Experimento de Validación — ASR-1 (Latencia) y ASR-2 (Escalabilidad)

**Caso:** Banco Z — Línea Verde · Apertura de CDT Digital de Alto Rendimiento
**Versión:** 1.0 · 2026-05-04
**Alcance:** Diseño metodológico (sin código, sin manifiestos, sin scripts).
**Lecturas previas:** `docs/reto_final.md`, `docs/ASRs.pdf`, `diagramas_final/`.

---

## 1. Resumen ejecutivo

Este documento define un **experimento de validación empírica** para los dos ASR de mayor prioridad de Línea Verde:

| ID | Atributo | Estímulo | Respuesta esperada | Prioridad |
|----|----------|----------|--------------------|-----------|
| **ASR-1** | Latencia | Confirmación de apertura de CDT en operación normal (800 req/h). | **< 800 ms** registrando la transacción de forma correcta. | Alta |
| **ASR-2** | Escalabilidad | Lanzamiento de tasa: pico de **6.000 solicitudes en 20 min**. | Apertura sin pérdida de solicitudes, manteniendo los tiempos de respuesta de ASR-1. | Alta |

El experimento adopta un enfoque **estocástico** (no determinista) porque los dos comportamientos observados que motivan estos ASR — operación normal y picos de lanzamiento de tasa — son fenómenos con **tasa de llegada variable**, **ráfagas correlacionadas en tiempo** y **think-time del cliente con cola pesada**. Una prueba con tráfico uniforme (constant arrival rate) ocultaría las patologías que el sistema realmente debe resistir: cold-starts del HPA, hot-spots por país, agotamiento del pool de conexiones del ACL hacia el core y backpressure del broker.

La validación se ejecuta sobre **un subconjunto mínimo viable** de la arquitectura final (ver §3), orquestado en un cluster Kubernetes local que reproduce la topología desplegada en OCI (`diagramas_final/despliegue.png`).

---

## 2. Interpretación operacional de los ASR

### 2.1 ASR-1 — Latencia

- **Métrica primaria:** tiempo end-to-end percibido por el cliente, desde que la app envía `POST /cdt` hasta recibir la confirmación (HTTP 202 Accepted con `cdtId`).
- **Umbral:** la respuesta esperada del ASR es `< 800 ms`. Para evitar falsos positivos por outliers se valida en **percentiles** (P95/P99), no en promedios — el promedio enmascara colas largas que sí afectan la experiencia real.
- **Convención de cumplimiento:**
  - **P95 < 800 ms** — cumplimiento del ASR.
  - **P99 < 1.500 ms** — guardrail interno (no aparece en el ASR pero es necesario para que el cumplimiento P95 sea estable bajo ráfagas).
- **Decisión arquitectónica que valida:** el CDT confirma al cliente con un **202 Accepted** tras escribir en `AlmacenCDTXPais` + outbox; la reserva real en el core ocurre asíncronamente (ver `secuencia.mmd`). El experimento debe demostrar que esta separación efectivamente desacopla la latencia del cliente de la latencia variable del core.

### 2.2 ASR-2 — Escalabilidad

- **Métrica primaria:** **throughput sostenido sin pérdida** durante 20 minutos.
- **Umbral compuesto:**
  1. **Volumen total:** 6.000 aperturas completadas en la ventana.
  2. **Tasa instantánea:** sobrevivir a ráfagas hasta **≥ 5× la tasa media** del intervalo.
  3. **Latencia bajo carga:** P95 mantiene el umbral del ASR-1 incluso durante el percentil más exigente del pico.
  4. **Pérdida cero:** 0 solicitudes con `5xx` definitivo (tras política de retry); 0 mensajes en DLQ del `MessageBroker`.
- **Decisión arquitectónica que valida:** el `ApiGateway` aplica throttling adaptativo, el `MessageBroker` absorbe el pico desacoplando del core, y el HPA + Cluster Autoscaler de OKE reaccionan en tiempo a la variabilidad de carga.

---

## 3. Subconjunto mínimo viable de componentes (en alcance)

Para ASR-1 y ASR-2, la **ruta crítica de escritura** de la apertura de CDT abarca exclusivamente los componentes que afectan la latencia del 202 y la capacidad de absorber el pico. Todo lo demás se excluye (no son post-confirmación o pertenecen a otros ASR).

### 3.1 Componentes en alcance

Tomados de la vista estructural en `diagramas_final/componentes.jpeg`:

| # | Subsistema | Componente | Rol en el experimento | Decisión arquitectónica que se prueba |
|---|------------|-----------|----------------------|---------------------------------------|
| 1 | Borde | `ApiGateway` | Throttling, rate limiting adaptativo, enrutamiento. | Que absorba ráfagas sin propagarlas íntegras al backend (ASR-2). |
| 2 | LineaVerde | `CDTXPais` (multi-país) | Orquesta apertura, escribe a `AlmacenCDTXPais`, publica outbox. | Que responda 202 en < 800 ms (ASR-1). |
| 3 | Datos | `AlmacenCDTXPais` (1 instancia/país) | Persistencia transaccional + tabla `outbox`. | Que el patrón outbox no degrade la latencia de escritura. |
| 4 | Asincrono | `MessageBroker` (tópico `cdt.eventos`) | Buffer asíncrono entre la respuesta al cliente y el core. | Que absorba el pico (ASR-2) sin pérdida. |
| 5 | Integracion | `ACL` (`AdaptadorCore` + `CircuitBreaker`) | Aísla al core. Se prueba el bulkhead. | Que el `CircuitBreaker` proteja al core sin generar pérdida hacia el cliente. |
| 6 | Externos | `CoreBancoZ` (**stub controlado**) | Genera latencia y errores realistas del core legacy. | No se prueba el core; se inyecta su comportamiento. |

### 3.2 Componentes fuera de alcance (justificación)

| Componente | Por qué se excluye |
|-----------|--------------------|
| `WAF`, `Autorizador` | Impacto en latencia es constante (~tens of ms); no contribuye a la varianza bajo pico. Se reemplaza por un cliente que ya emite el JWT pre-firmado. |
| `OnboardingXPais`, `ValidadorIdentidad` | Se asume cliente ya onboarded; KYC fuera del flujo de apertura recurrente. |
| `MotorElegibilidadXPais`, `CreditoExpressXPais` | Pertenecen a ASR-3 (elegibilidad < 10 min), fuera de la ruta de apertura. |
| `Pagos`, `Convenios` | Fuera del flujo de CDT. |
| `ChangeDataCapture`, `ActualizadorCache`, `CacheDistribuido` | Resuelven ASR-4 (consistencia de saldos). No están en la ruta de escritura de apertura. |
| `DetectorFraude`, `LogAuditoria` | Resuelven ASR-8 (seguridad post-apertura). |
| `Notificaciones` | Consumidor del broker, no afecta el 202. |

### 3.3 Topología de la prueba

```
[k6 v0.53 · ramping-arrival-rate · módulo estocástico JS]
        │  (HTTP/2, JWT preconstruido)
        ▼
   [Kong Gateway 3.7 OSS]               ── plugin rate-limiting + prometheus
        │
        ▼
   [CDTXPais (Spring Boot 3.3, Java 21, virtual threads) × N pods × 3 países]
        │              ── HPA v2 target CPU 60 %, min=2, max=20
        │      │
        │      └──> [PostgreSQL 16 · CloudNativePG · 1 cluster/país]
        │            schemas: cdt + outbox (transacción ACID conjunta)
        ▼
   [Redpanda 24.2 · tópico cdt.eventos · 6 particiones · RF=3]
        │
        ▼
   [ACL (Spring Boot + Resilience4j 2.2: CircuitBreaker + Bulkhead)]
        │           ── 1 deployment, HikariCP max=20
        ▼
   [CoreBancoZ-stub (Spring Boot + Apache Commons Math)]
                   inyecta latencia ~ Pareto, errores ~ Bernoulli(p)

Observabilidad transversal: Prometheus 2.55 + Grafana 11.3 +
                             Tempo 2.6 + Loki 3.x + OTel Collector 0.110
Plataforma: kind v0.23 (Kubernetes 1.30) en local · paridad con OKE 1.30
```

El multiplicador de países `P` (típicamente 3 para representar la realidad operativa) **es esencial**: sin sharding multi-país no se puede probar el hot-spot pattern del ASR-2 (un país que lanza tasa antes que los demás).

---

## 4. Modelado estocástico de carga (núcleo del experimento)

### 4.1 Por qué estocástico y no determinista

Una prueba determinista (p. ej. *constant arrival rate* a 5 req/s durante 20 min) entrega el volumen total del ASR-2 (6.000 req) pero **no valida la propiedad real**: el sistema debe sobrevivir a la **forma** del pico, no solo a su volumen. En un lanzamiento de tasa, la curva real de tráfico tiene:

1. **Onset abrupto** correlacionado con la publicación del anuncio.
2. **Decaimiento heterogéneo** por husos horarios (operación en 5 países).
3. **Ráfagas internas** por viralidad (un cliente comparte el lanzamiento, otros entran en cluster temporal).
4. **Cola larga** después del minuto 20.

Modelar esto exige procesos estocásticos. La prueba determinista pasaría incluso si el HPA tarda 90 s en escalar — porque el tráfico uniforme nunca pondría a prueba el cold-start. La prueba estocástica fuerza al sistema a **demostrar elasticidad bajo incertidumbre**.

### 4.2 Modelo de llegadas — Proceso de Poisson No-Homogéneo (NHPP) con superposición de ráfagas

#### 4.2.1 Tasa media variable λ(t)

Las llegadas siguen un **proceso de Poisson no-homogéneo** con función de intensidad `λ(t)` que captura la curva del lanzamiento:

| Fase del pico (min) | λ(t) — solicitudes/segundo | Justificación |
|---------------------|---------------------------|---------------|
| 0 – 2 | 12 req/s | Onset abrupto: el anuncio se publica y entran los clientes esperando. |
| 2 – 7 | 9 → 6 req/s (decaimiento exponencial) | Pico sostenido con descenso natural. |
| 7 – 15 | 5 → 3 req/s | Régimen estable cercano a la media nominal. |
| 15 – 20 | 3 → 2 req/s | Cola del lanzamiento. |

> **Verificación de volumen:** la integral de `λ(t)` sobre [0, 1.200 s] debe aproximar 6.000 (criterio del ASR-2). Esta función produce ≈ 6.080 ± 200 req por simulación, dentro de la tolerancia esperada.

Las **inter-arrivals** son `Exponencial(λ(t))` evaluada en tiempo continuo — es la firma del Poisson y la propiedad clave que el generador de carga debe preservar. Una secuencia uniforme con la misma tasa media **no es Poisson**.

#### 4.2.2 Ráfagas correlacionadas — Markov-Modulated Poisson Process (MMPP-2)

Por encima del NHPP base se superpone un **MMPP de dos estados** (calmo / bursty) con matriz de transición ajustada para que el sistema esté en `bursty` ~15 % del tiempo, multiplicando λ(t) por 3× en esos intervalos. Esto modela la viralidad social del lanzamiento:

- Estado `calmo` → tasa = λ(t).
- Estado `bursty` → tasa = 3·λ(t) durante intervalos de duración `Exponencial(media=20 s)`.
- Tiempo medio entre ráfagas: 90 s.

El MMPP es el mecanismo que materializa el pico instantáneo de **≥ 25 req/s** que el ASR-2 sugiere ("durante estos picos la app ha presentado tiempos de respuesta inaceptables").

#### 4.2.3 Distribución por país — sharding desigual

Las 6.000 solicitudes se reparten entre los `P` países con **una Dirichlet(α)** para inducir asimetría (un país lanza primero o tiene más usuarios). Con `α = (3, 1, 1)` se obtiene una distribución típica `(60 %, 25 %, 15 %)`, validando que el shard mayoritario no colapsa mientras los menores siguen disponibles.

Este componente del modelo es lo que valida la **elasticidad por shard**: la promesa multi-país (`AlmacenCDTXPais`, `CDTXPais` con `pais : Pais`) debe absorber concentración de carga sin propagar contención al resto.

### 4.3 Variables aleatorias del cliente y del backend

El generador inyecta variabilidad adicional para que cada solicitud sea distinguible y los efectos de cola se manifiesten.

| Variable | Distribución | Parámetros | Razón |
|----------|--------------|-----------|-------|
| Tamaño de payload (`SolicitudCDT` JSON) | **Lognormal** | μ=ln(2 KB), σ=0.4 | Mayoría compactos, ocasionales grandes (clientes con datos KYC ya enriquecidos). |
| Latencia inyectada en `CoreBancoZ-stub` | **Pareto Tipo II (Lomax)** | xm=80 ms, α=2.5 | Cola pesada característica de mainframes con CICS y bloqueos ocasionales. |
| Tasa de error del core stub | **Bernoulli** | p=0.5 % nominal, p=2 % en estado `bursty` | Validar que el `CircuitBreaker` abre y se recupera. |
| Think-time entre solicitudes del mismo cliente (en ASR-1) | **Lognormal** | μ=ln(8 s), σ=0.6 | Clientes humanos no son Poisson en sesión. |
| País de origen | **Dirichlet** | α=(3,1,1) | Concentración asimétrica por país, ver §4.2.3. |

### 4.4 Cómo este modelo valida la elasticidad bajo incertidumbre

Cada elemento estocástico ataca una hipótesis arquitectónica concreta:

| Mecanismo estocástico | Hipótesis que prueba | Componente validado |
|----------------------|----------------------|---------------------|
| NHPP con onset abrupto | El HPA reacciona en `< 30 s` antes de que la cola del `ApiGateway` desborde. | OKE HPA + Cluster Autoscaler. |
| MMPP-2 (ráfagas) | El throttling adaptativo del gateway convierte un pico instantáneo de 25 req/s en una entrega sostenida. | `ApiGateway` (rate limiting). |
| Dirichlet por país | Un shard caliente no degrada a los demás (no hay recurso global compartido en la ruta crítica). | `AlmacenCDTXPais` por país, `CDTXPais` con afinidad por país. |
| Pareto en core stub | El timeout y el `CircuitBreaker` aíslan el blast radius cuando el core entra en cola larga. | `ACL` (`AdaptadorCore` + `CircuitBreaker`). |
| Lognormal en payload | El procesamiento JSON no agrega varianza patológica al P99. | Serializadores + tamaño de heap del pod. |
| Bernoulli de errores | Los reintentos no producen avalancha (efecto retry storm). | Política de retry con jitter + DLQ del broker. |

---

## 5. Validación de latencia P95 / P99 durante el test estocástico

### 5.1 Metodología de medición

- **Histogramas, no promedios.** Cada punto de instrumentación expone un histograma de Prometheus con buckets ajustados al rango de interés:
  `[10, 25, 50, 100, 200, 400, 600, 800, 1000, 1500, 2500, 5000, 10000] ms`.
  El bucket `800 ms` es deliberado: encuadra el límite del ASR-1.
- **Percentiles vía `histogram_quantile`** sobre ventanas móviles de **1 minuto** (resolución mínima para distinguir el efecto de una ráfaga del MMPP-2) y agregados sobre la ventana completa de 20 min para el reporte final.
- **Stratified percentiles:** P95/P99 se calculan globalmente y por dimensión: `por país`, `por pod`, `por bucket de payload-size`, `por estado del CB (CLOSED/OPEN/HALF_OPEN)`. Así se atribuye una falla a su shard responsable.
- **Coordinated omission** se evita usando **k6 v0.53** con executor `ramping-arrival-rate`: la tasa de llegada es independiente de los tiempos de respuesta del backend y se mantiene aunque la cola del backend crezca. En *Closed-Workload* (un pool fijo de VUs) un backend lento haría caer la tasa real y enmascararía la degradación. Se descarta Locust porque su modelo `LoadTestShape` deriva el spawning de la tasa de forma aproximada y no garantiza el desacople requerido.

### 5.2 Puntos de instrumentación en la arquitectura

Todos referenciados contra `diagramas_final/componentes.jpeg`. Cada punto emite spans OpenTelemetry y un histograma Prometheus.

| # | Punto | Métrica | Para qué sirve |
|---|-------|---------|----------------|
| **P1** | Cliente sintético (k6) | `http_req_duration` end-to-end. | Latencia percibida — la que valida directamente ASR-1. |
| **P2** | Egreso del `ApiGateway` hacia `CDTXPais` | `gateway_upstream_latency` y `gateway_queue_time`. | Aísla el costo del throttling y del rate limiting. |
| **P3** | Entrada y salida de `CDTXPais` (por país) | `cdt_open_handler_duration`. | Latencia de servicio puro, sin red ni gateway. |
| **P4** | Repositorio → `AlmacenCDTXPais` | `cdt_db_write_duration` (incluye `INSERT cdt + outbox` en una sola transacción). | Que la escritura ACID con outbox no se convierta en el cuello de botella. |
| **P5** | Publicación al `MessageBroker` (outbox dispatcher) | `outbox_publish_duration`, `outbox_lag_seconds`. | Que la publicación post-commit no añada latencia al cliente (es asíncrona) y que el lag no crezca durante el pico. |
| **P6** | `ACL` → `CoreBancoZ` (stub) | `core_call_duration`, `circuit_breaker_state`. | Detectar apertura del CB y validar aislamiento. |
| **P7** | Recursos del cluster | `kube_pod_status_ready`, `hpa_replicas`, `node_load1`, `kafka_consumer_lag`. | Métricas de plataforma que explican el comportamiento de los percentiles. |

> El cliente es la fuente autoritativa para el SLA de ASR-1 (P1). Los puntos internos (P2–P6) son **diagnósticos**: explican *por qué* se cumple o se incumple, pero el ASR se mide en P1.

---

## 6. Configuración del experimento

### 6.1 Observabilidad

El stack de observabilidad debe estar instalado **antes** de ejecutar la primera prueba; sin él, el experimento no produce evidencia.

#### 6.1.1 Métricas (RED + USE)

**RED** — para servicios HTTP (`ApiGateway`, `CDTXPais`):

- **Rate** (req/s) por endpoint, por país, por pod.
- **Errors** (%) — `5xx`, `4xx-de-throttling`, timeouts del cliente.
- **Duration** — histogramas en P1, P3, P6 (§5.2).

**USE** — para componentes de infraestructura:

- **Utilization** — CPU/memoria por pod, conexiones DB ocupadas, particiones del broker en uso.
- **Saturation** — pods en `Pending` (cluster autoscaler frío), profundidad de cola del HPA, `kafka_consumer_lag`, longitud del `connection-pool-wait` del ACL.
- **Errors** — pods en `CrashLoopBackOff`, mensajes en DLQ, fallas de probe.

#### 6.1.2 Métricas de negocio específicas del ASR

| Métrica | Cómo se calcula | Umbral |
|---------|-----------------|--------|
| `cdt_aperturas_completadas_total` | Counter incrementado cuando `CDTXPais` retorna 202 con `cdtId` válido. | = volumen total inyectado (pérdida cero). |
| `cdt_aperturas_perdidas_total` | Counter incrementado en cada `5xx` definitivo o timeout sin retry exitoso. | = 0. |
| `latency_sla_violation_ratio` | `(reqs con duration > 800 ms) / total`. | ≤ 5 % (equivalente a P95 < 800 ms). |
| `broker_dlq_messages_total` | Mensajes que terminan en la cola de letras muertas del broker. | = 0. |
| `circuit_breaker_open_seconds` | Tiempo acumulado del CB en estado OPEN durante el test. | Documentado, no hay umbral; sirve para correlacionar. |

#### 6.1.3 Trazas

OpenTelemetry distribuido con sampling adaptativo: 100 % durante los primeros 30 s del test (para diagnosticar el onset), y 1 % en estado estable. El trace ID se propaga desde k6 hasta el ACL como header `traceparent`.

#### 6.1.4 Logs

Logs estructurados (JSON) agregados en Loki (en local) o OCI Logging Analytics (en prod). Solo se buscan eventos discretos: aperturas de CB, fallas de retry, eventos de HPA/Cluster Autoscaler.

### 6.2 Recursos de simulación — Kubernetes local

El experimento debe ser **representativo** (mantener la topología) pero **ejecutable localmente** (no requiere OCI para iterar el diseño de carga).

#### 6.2.1 Cluster local

- **kind v0.23** corriendo Kubernetes **v1.30** sobre Docker Desktop o WSL2. 4 nodos virtuales (1 control-plane, 3 workers) para simular las 3 *Availability Domains* de OCI.
- **Recursos host recomendados:** 16 GB RAM, 8 vCPU, 50 GB SSD. La carga del ASR-2 es factible en local porque la mayoría del cómputo es I/O.
- Se descarta **k3d** porque k3s usa una distribución no idéntica a OKE (omite componentes que el experimento valida, como el `metrics-server` v0.7 con la misma versión que OKE).

#### 6.2.2 Componentes desplegados en el cluster

> Las elecciones tecnológicas de esta tabla son **definitivas** y se desarrollan en detalle en §6.4 (stack consolidado).

| Componente real (OCI) | Equivalente local pinneado | Por qué es una sustitución válida |
|----------------------|----------------------------|----------------------------------|
| OCI API Gateway | **Kong Gateway 3.7 OSS** (DB-less) en namespace `borde` con plugins `rate-limiting-advanced`, `prometheus`, `opentelemetry`. | Mismo modelo de rate limiting y throttling adaptativo, paridad de plugins con OCI APIGW. |
| OKE Node Pool + HPA | **kind v0.23** + `metrics-server` 0.7 + **HPA v2** + Cluster Autoscaler simulado. | El HPA es el mismo objeto de Kubernetes; el comportamiento de scheduling difiere ligeramente pero la prueba lo captura con la misma `apiVersion`. |
| Autonomous DB (ATP) | **PostgreSQL 16.4** vía operador **CloudNativePG 1.24**, **un cluster por país** (3 clusters en total), schemas `cdt` + `outbox` por cluster. | Lo que se prueba es contención por shard y latencia de write con outbox, que se reproduce con Postgres. ATP solo difiere en auto-scaling vertical, modelado por `resources.limits` agresivos. |
| OCI Streaming | **Redpanda 24.2** vía Redpanda Operator, **6 particiones** en `cdt.eventos`, RF=3. + **Apicurio Registry 3.0** como Schema Registry. | Idéntica semántica de particiones y consumer groups (Kafka API). Footprint local más bajo que Strimzi/Kafka tradicional. |
| OCI Functions (consumer del outbox) | Deployment **outbox-dispatcher** (Spring Boot, 1 réplica) que poltea la tabla `outbox_cdt_eventos` y publica a Redpanda. | Función de tooling, no se prueba elasticidad de funciones aquí. |
| FastConnect → Core | **CoreBancoZ-stub** (Spring Boot WebFlux + Apache Commons Math) con perfil de latencia Pareto y errores Bernoulli (§4.3). | El core real está fuera del alcance del experimento. |

#### 6.2.3 Aislamiento de la prueba

- Namespaces: `borde`, `linea-verde`, `datos`, `asincrono`, `acl`, `core-stub`, `observabilidad`, `carga`.
- `NetworkPolicies` que reflejen las dependencias del diagrama de componentes (un servicio de Línea Verde no puede saltarse el ACL).
- `ResourceQuotas` por namespace para evitar que un componente acapare el cluster local y enmascare la saturación real de su par.

### 6.3 Procedimiento de ejecución (ronda)

Cada **ronda** de validación consta de tres etapas, ejecutadas en orden:

1. **Calentamiento** (5 min, tasa constante 2 req/s) — alinea los JIT, llena conexiones de pool, descarta el cold-start del Postgres.
2. **Línea base ASR-1** (15 min, NHPP con λ=0.22 req/s ≈ 800/h) — registro autoritativo de los percentiles bajo carga nominal.
3. **Pico ASR-2** (20 min, NHPP + MMPP-2 + Dirichlet, §4.2) — registro autoritativo de la curva de cumplimiento bajo estrés.

Cada ronda se repite **N ≥ 5 veces** con seeds aleatorias diferentes para que los percentiles reportados sean estadísticamente robustos (se reporta P95 medio ± desviación entre rondas).

### 6.4 Stack tecnológico consolidado

> Esta sección es la **fuente de verdad** de las decisiones tecnológicas del experimento. El resto del documento referencia los productos definidos aquí. Cada elección está pinneada — no hay alternativas sin justificación explícita.

#### 6.4.1 Lenguajes y runtimes

| Componente | Lenguaje | Runtime / Versión | Justificación de la elección |
|-----------|----------|-------------------|------------------------------|
| `CDTXPais` | Java | **Java 21 LTS** (Eclipse Temurin) | Estándar bancario; ecosistema Spring + Resilience4j maduro; el cold-start del JVM es **honesto** (no se enmascara como sí lo haría con Go nativo). |
| `ACL` (`AdaptadorCore`, `CircuitBreaker`, `TraductorDominio`) | Java | Java 21 LTS | Misma plataforma para uniformidad operacional; Resilience4j es nativo del ecosistema. |
| Outbox dispatcher | Java | Java 21 LTS | Comparte código de persistencia con `CDTXPais`. |
| `CoreBancoZ` (stub) | Java | Java 21 LTS | Inyección de Pareto/Bernoulli vía Apache Commons Math; mismo runtime simplifica build. |
| Generador de carga | JavaScript (k6) | **k6 v0.53** (Go embebido) | Soporte nativo de `ramping-arrival-rate`, footprint bajo, salida nativa a Prometheus. |
| Infraestructura como código | HCL / YAML | Terraform 1.9, Helm 3.15, Kustomize | Estándares del ecosistema OCI / Kubernetes. |

> **Decisión clave de concurrencia:** los servicios usan **virtual threads** (Project Loom, Java 21) habilitados con `spring.threads.virtual.enabled=true`. Entrega la concurrencia equivalente a WebFlux con la simplicidad sintáctica del modelo thread-per-request, y permite usar JDBC bloqueante sin riesgo de bloquear un event loop.

#### 6.4.2 Frameworks y librerías de aplicación

| Capa | Tecnología | Versión | Rol |
|------|-----------|:-------:|-----|
| Web framework | **Spring Boot** | 3.3.x | Servlet stack con virtual threads, controlador REST. |
| Persistencia | **Spring Data JDBC** + **HikariCP** | Spring Data 3.3 / HikariCP 5.x | Repositorio ACID sobre Postgres, pool acotado a 20 conexiones por pod. |
| Resiliencia | **Resilience4j** | 2.2.x | `CircuitBreaker`, `Bulkhead`, `RateLimiter`, `Retry` con jitter. |
| Cliente Kafka | **Spring Kafka** | 3.2.x (Kafka client 3.7) | Producer al broker, opcional transaccional para outbox. |
| Métricas | **Micrometer** + **micrometer-registry-prometheus** | 1.13.x | Histogramas con los buckets de §5.1. |
| Trazas | **OpenTelemetry Java agent** | 2.x | Auto-instrumentación HTTP, JDBC, Kafka — sin cambios de código. |
| Estadística (stub) | **Apache Commons Math** | 3.6.x | Samplers Pareto, Bernoulli, Lognormal. |
| Build | **Gradle Kotlin DSL** + **Jib** | Gradle 8.10 / Jib 3.4 | Build de imagen OCI sin Dockerfile, reproducible. |
| Imagen base | `eclipse-temurin:21-jre-jammy` | – | OpenJDK oficial; opción de migrar a distroless si lo exige Cumplimiento. |

#### 6.4.3 Persistencia (`AlmacenCDTXPais`)

| Tema | Decisión |
|------|---------|
| Motor | **PostgreSQL 16.4** |
| Operador K8s | **CloudNativePG 1.24** (preferido sobre Zalando por integración con HPA y nativo OTel) |
| Topología | **1 cluster por país** — 3 países en el experimento (`pe`, `mx`, `co`); cada cluster con 1 primary + 1 standby (HA local). |
| Schemas | `cdt.cdt` (tabla principal) + `cdt.outbox_cdt_eventos`; INSERT en ambas tablas dentro de la **misma transacción ACID**. |
| Pool de conexiones | HikariCP, `maximumPoolSize=20` por pod (multiplicado por `replicas` según HPA). |
| Volumen | PVC con StorageClass `standard` — host-path en kind, **OCI Block Volume** en OKE. |
| Equivalente OCI | **Autonomous DB (ATP)**, una instancia por país. |

#### 6.4.4 Mensajería (`MessageBroker`)

| Tema | Decisión |
|------|---------|
| Broker | **Redpanda 24.2** (Kafka-API compatible, single-binary, sin ZooKeeper) |
| Operador | **Redpanda Operator** |
| Configuración | 3 brokers, replication factor=3, **6 particiones** por tópico (≥ países × 2 para evitar hot-partition por país). |
| Schema Registry | **Apicurio Registry 3.0** (open source, AsyncAPI 3.0 / Avro / JSON Schema). |
| Tópicos en alcance | `cdt.eventos`. Otros tópicos del modelo (`saldo.cambios`, `credito.eventos`, `eventos`) se declaran pero no se consumen en este experimento. |
| Política de DLQ | `cdt.eventos.DLQ` con retención 7 días para auditoría AC-2.4. |
| Equivalente OCI | **OCI Streaming** (mismo Kafka API). |

#### 6.4.5 Borde — API Gateway

| Tema | Decisión |
|------|---------|
| Producto | **Kong Gateway 3.7 OSS** (DB-less mode, configuración declarativa). |
| Plugins activos | `rate-limiting-advanced`, `request-size-limiting`, `correlation-id`, `prometheus`, `opentelemetry`. |
| Configuración | Throttling adaptativo por consumer-id; límite global de 60 req/s con burst de 50 (parametrizable por entorno). |
| WAF / Autorizador | Excluidos del experimento (§3.2). El cliente k6 inyecta JWT preconstruido. |
| Equivalente OCI | **OCI API Gateway**. |

#### 6.4.6 Plataforma de orquestación

| Tema | Local | OCI (producción) |
|------|-------|------------------|
| Distribución | **kind v0.23** | **OKE** (Oracle Kubernetes Engine) |
| Versión Kubernetes | **1.30** | **1.30** |
| Topología | 1 control-plane + 3 workers (simulan 3 ADs) | Control plane gestionado + node pool multi-AD |
| Recursos | 16 GB RAM, 8 vCPU, 50 GB SSD | `VM.Standard.E5.Flex` autoscaling 3-12 nodos |
| Networking | CNI por defecto (`kindnet`) | OCI VCN-native CNI |
| Autoscaling | `metrics-server` 0.7 + **HPA v2** + Cluster Autoscaler simulado | `metrics-server` + **HPA v2** + Cluster Autoscaler real |
| Empaquetado | **Helm 3.15** + **Kustomize** | Helm 3.15 + Terraform |

#### 6.4.7 Observabilidad

| Función | Producto | Versión | Notas |
|---------|---------|:-------:|------|
| Stack base | **kube-prometheus-stack** | 65.x | Empaqueta Prometheus, Alertmanager, Grafana, exporters. |
| Métricas | **Prometheus** | 2.55.x | Retención 7 días en local. |
| Visualización | **Grafana** | 11.3.x | Dashboards provisionados via ConfigMap. |
| Trazas | **Grafana Tempo** | 2.6.x | Backend OTLP, integrado con Grafana. |
| Logs | **Grafana Loki** + **Promtail** | 3.x | Logs estructurados JSON, queries por label. |
| Pipeline OTel | **OpenTelemetry Collector** | 0.110.x | Daemonset; ruteo a Tempo (trazas) y Prometheus (métricas adicionales). |
| Métricas plataforma | **kube-state-metrics** + **node-exporter** | – | Built-in del stack. |
| Equivalente OCI | OCI Logging Analytics + APM Tracing + OCI Monitoring | – | Para corrida en cloud. |

#### 6.4.8 Generación de carga

| Tema | Decisión |
|------|---------|
| Herramienta | **k6 v0.53** (open source, Grafana Labs). |
| Ejecutor | `ramping-arrival-rate` (independiza la tasa de llegada de la tasa de respuesta del backend — evita coordinated omission). |
| Extensiones | **xk6-distribution** (Lognormal, Pareto, Exponential, Dirichlet) y **xk6-output-prometheus-remote-write**. |
| Patrón estocástico | NHPP + MMPP-2 + Dirichlet implementados como módulo JavaScript con seeds reproducibles vía `seedrandom`. |
| Orquestación | **k6-operator 0.0.16** para corridas in-cluster; alternativamente ejecución desde host vía `kubectl port-forward`. |
| Reportes | k6 export `summary.json` + push de métricas a Prometheus durante la corrida. |

#### 6.4.9 CI/CD y artefactos

| Función | Producto | Notas |
|---------|---------|------|
| CI | **GitHub Actions** | Pipeline reproducible (ver §8 Fase D). |
| Registry de imágenes | **OCIR** (OCI Container Registry) en producción; in-cluster registry de kind en local. |
| Repositorio | Mono-repo con módulos por servicio. |
| Build de imágenes | **Gradle multi-proyecto** + **Jib**, sin Dockerfile. |
| IaC | **Terraform 1.9** + **OCI Provider 6.x**. |

#### 6.4.10 Tabla maestra de versiones

| Capa | Producto | Versión |
|------|---------|:-------:|
| JDK | Eclipse Temurin | **21 LTS** |
| Spring Boot | Spring Boot | **3.3.x** |
| Resiliencia | Resilience4j | **2.2.x** |
| Build | Gradle / Jib | **8.10** / **3.4** |
| Cluster local | kind | **0.23** |
| Cluster cloud | OKE | **1.30** |
| Kubernetes | Kubernetes | **1.30** |
| API Gateway | Kong OSS | **3.7** |
| Broker | Redpanda | **24.2** |
| Schema Registry | Apicurio | **3.0** |
| DB | PostgreSQL | **16.4** |
| DB operator | CloudNativePG | **1.24** |
| Métricas | Prometheus | **2.55** |
| Visualización | Grafana | **11.3** |
| Trazas | Tempo | **2.6** |
| Logs | Loki | **3.x** |
| Pipeline OTel | OpenTelemetry Collector | **0.110** |
| Carga | k6 | **0.53** |
| IaC | Terraform | **1.9** |

#### 6.4.11 Portabilidad y matices kind ↔ OCI

> Esta subsección documenta dónde la **paridad local ↔ OCI no es 100 %** para evitar que el lector asuma intercambiabilidad total. Es información que un evaluador o auditor preguntará al revisar el stack.

##### Lo que sí es idéntico en kind y OKE

Los siguientes componentes se instalan con **el mismo Helm chart, la misma imagen y la misma configuración** en kind (local) y OKE (OCI). Esto es lo que sostiene la paridad del experimento:

- Spring Boot + Java 21 + virtual threads (todos los servicios `CDTXPais`, `ACL`, outbox dispatcher, stub).
- Kong Gateway 3.7 OSS, Redpanda 24.2, Apicurio Registry 3.0.
- PostgreSQL 16 + CloudNativePG 1.24.
- kube-prometheus-stack 65.x (Prometheus, Grafana, Alertmanager), Tempo 2.6, Loki 3.x, OpenTelemetry Collector 0.110.
- k6 0.53 + k6-operator + xk6-distribution + xk6-output-prometheus-remote-write.
- Helm 3.15, Kustomize, Jib 3.4 (herramientas cliente, agnósticas).

Para todos estos, `kubectl apply` o `helm install` con el mismo chart funciona en ambos entornos.

##### Tres matices donde la portabilidad NO es total

###### Matiz 1 — `kind` no se instala en OCI

`kind` es una distribución de Kubernetes diseñada **exclusivamente para desarrollo local** (corre cada nodo como un contenedor Docker en la máquina del desarrollador). En OCI **se reemplaza por OKE**, no se "instala kind sobre OCI Compute". La paridad real es a nivel de **API de Kubernetes** (`apiVersion: apps/v1`, recursos `Deployment`, `Service`, `HPA`), no de distribución. Esto es por diseño y no representa un riesgo, porque los manifiestos del experimento solo dependen de la API estándar de K8s 1.30.

###### Matiz 2 — La arquitectura productiva canónica usa servicios gestionados de OCI

El diagrama `diagramas_final/despliegue.png` indica que la versión productiva usa servicios gestionados, **no las versiones self-hosted que despliega el experimento**. La siguiente tabla aclara la diferencia:

| Servicio en `despliegue.png` (productivo) | Lo que el experimento despliega en ambos entornos | Drop-in al pasar a productivo? |
|-------------------------------------------|---------------------------------------------------|-------------------------------|
| **OCI API Gateway** (gestionado) | **Kong Gateway 3.7 OSS** self-hosted | Sí, traduciendo configuración declarativa de Kong a especificación de OCI APIGW. No requiere cambios de código de cliente. |
| **OCI Streaming** (gestionado) | **Redpanda 24.2** self-hosted | Sí, ambos exponen Kafka API. Solo cambia el bootstrap server y el modo de autenticación (SASL/IAM). |
| **Autonomous DB ATP** (gestionado, **Oracle DB**) | **PostgreSQL 16** + CloudNativePG self-hosted | **NO drop-in**. Oracle y Postgres son motores diferentes (dialecto SQL, tipos, driver, secuencias). Ver matiz 3. |
| **OCI Cache for Redis** (gestionado) | (fuera de alcance del experimento) | N/A — no usado para ASR-1/ASR-2. |
| **OCI Logging Analytics / APM Tracing / Monitoring** | **Loki + Tempo + Prometheus** self-hosted | No drop-in: distinto agente de ingestión, distinto query language (LogQL/PromQL vs OCI Logging Search). Requiere reconfigurar exporters. |

**Decisión arquitectónica del experimento:** se usa la versión self-hosted **en ambos entornos** (kind y OKE) para garantizar que la corrida local y la corrida en OKE ejecutan **exactamente el mismo binario**. Esto evita la clase de bug que solo aparece en cloud por diferencia de runtime gestionado, y permite atribuir cualquier diferencia de resultados a factores legítimos (recursos, latencia de red, scheduler de OKE) y no a la sustitución de productos.

**Cuándo migrar a los gestionados:** después de que el experimento valide los AC-* en OKE con la versión self-hosted, una corrida de regresión opcional con los servicios gestionados confirma que la migración productiva no introduce regresión. Esa corrida de regresión queda fuera del alcance de este documento.

###### Matiz 3 — Caso especial: Autonomous DB ATP es Oracle, no PostgreSQL

Este es el matiz con mayor blast-radius. La arquitectura productiva indica `Autonomous DB (ATP)`, que es **Oracle Database**. El experimento usa **PostgreSQL** vía CloudNativePG. Las dos no son compatibles a nivel de driver ni de dialecto SQL. Hay tres caminos posibles para resolverlo:

| Opción | Descripción | Trade-off |
|--------|------------|-----------|
| **A. Mantener Postgres en experimento, migrar a ATP en producción** (default) | Experimento valida la arquitectura con Postgres; al desplegar productivo se traduce el repositorio JDBC a Oracle (driver `ojdbc11`, dialecto Hibernate Oracle, secuencias en lugar de `SERIAL`, etc.). | Cambios localizados en la capa de persistencia del servicio. El comportamiento de latencia bajo carga puede diferir — especialmente bajo contención de write-locks. |
| **B. Cambiar la decisión arquitectónica a OCI Database with PostgreSQL** (gestionado) | OCI ofrece un servicio gestionado de PostgreSQL desde 2022. Es **drop-in** con CloudNativePG (mismo wire protocol, mismo driver, mismo dialecto). | Requiere actualizar `despliegue.png` para reemplazar `Autonomous DB ATP` por `OCI Database with PostgreSQL`. La decisión debe validarse con Cumplimiento (ATP tiene certificaciones específicas que el equipo del banco puede haber elegido por razones regulatorias). |
| **C. Correr el experimento contra ATP real en OKE** | Aprovisionar una instancia ATP de prueba y conectar el experimento. | Rompe la paridad local (kind no puede correr ATP). Hace que el experimento sea más costoso y menos iterable. Solo recomendable como ronda de aceptación final, no como ronda de iteración. |

**Recomendación del experimento:** seguir **opción A** durante la fase de validación de ASR-1/ASR-2 (rapidez de iteración, paridad kind ↔ OKE) y reservar **opción C** para una ronda final de aceptación productiva. Si el equipo del banco aún no ha cerrado la decisión entre ATP y OCI Database with PostgreSQL, se sugiere **escalar la conversación con el CIO**: la opción B reduce significativamente el riesgo técnico del programa Línea Verde sin comprometer requerimientos regulatorios documentados.

##### Componentes que no se instalan en ningún K8s

| Componente | Naturaleza |
|-----------|-----------|
| **GitHub Actions** | SaaS de GitHub. No se instala en kind ni en OKE. Despliega contra ambos. Si Cumplimiento del banco prohíbe SaaS externo de CI, se reemplaza por **Jenkins** o **GitLab Runner** sobre OKE — ambos self-hosteables — sin afectar el resto del stack. |
| **Terraform CLI** | Herramienta cliente que corre en la máquina del operador (laptop o agente CI). No se "instala en OCI". |
| **kubectl, helm, kustomize, jib** | Idem — clientes locales. |

##### Resumen para presentación

| Bucket | Componentes | Portabilidad |
|--------|------------|:------------:|
| **Idénticos en kind y OKE** | Spring Boot, Kong, Redpanda, Apicurio, Postgres+CloudNativePG, Prometheus stack, Tempo, Loki, OTel Collector, k6 | ✅ 100 % |
| **Sustitutos por entorno** | kind ↔ OKE | API K8s idéntica |
| **Self-hosted en experimento, gestionado en producción** | Kong vs OCI APIGW; Redpanda vs OCI Streaming; Loki/Tempo/Prometheus vs OCI Logging/APM/Monitoring | Drop-in a nivel de protocolo |
| **Cambio de motor (no drop-in)** | Postgres vs Autonomous DB ATP (Oracle) | ⚠️ Requiere decisión arquitectónica |
| **Externos al cluster** | GitHub Actions, Terraform CLI | N/A |

---

## 7. Criterios de aceptación

El experimento se considera **aprobado** si, sobre N=5 rondas independientes, se cumplen simultáneamente:

| ID | Criterio | Umbral |
|----|---------|--------|
| AC-1.1 | P95 de `http_req_duration` (P1) durante línea base ASR-1. | **< 800 ms** en cada ronda. |
| AC-1.2 | P99 de `http_req_duration` durante línea base ASR-1. | **< 1.500 ms** en cada ronda (guardrail). |
| AC-2.1 | Volumen completado durante el pico ASR-2. | **≥ 6.000 aperturas con 202 OK** sin contar reintentos. |
| AC-2.2 | `cdt_aperturas_perdidas_total` al final del pico. | **= 0** en cada ronda. |
| AC-2.3 | P95 sostenido durante el pico, agregado por minuto. | **< 800 ms** en al menos **18 de 20** minutos. |
| AC-2.4 | `broker_dlq_messages_total`. | **= 0** en cada ronda. |
| AC-2.5 | Tiempo desde que `replicas_pending > 0` hasta que `replicas_ready` alcanza el target HPA. | Documentado y < 60 s en p90. |
| AC-2.6 | El `CircuitBreaker` debe abrir y cerrar correctamente cuando el core stub eleva su tasa de error a 2 %. | **Ningún caso** donde el CB queda OPEN > 90 s con el core sano. |

Si un criterio falla, el experimento entrega un reporte indicando **cuál hipótesis arquitectónica fue refutada** (mapeo en §4.4) — esto orienta el rediseño antes de la siguiente ronda.

---

## 8. Hoja de ruta de implementación (siguientes fases)

> Este documento es el **diseño metodológico**. La ejecución del experimento requiere construir los artefactos que se listan a continuación. Cada uno es una pieza concreta de trabajo posterior.

### Fase A — Infraestructura base
1. **Manifiestos Kubernetes (YAML)** para cada componente del §3.3: `Deployment`, `StatefulSet` (Postgres, Kafka), `Service`, `HorizontalPodAutoscaler`, `NetworkPolicy`, `PodDisruptionBudget`, `ServiceMonitor`.
2. **Helm charts** o **Kustomize overlays** que parametricen `P` (número de países) y `M` (particiones del broker).
3. **Scripts de aprovisionamiento OCI** (Terraform + OCI CLI) equivalentes para una corrida de validación en cloud: OKE node pool, Autonomous DB (ATP), OCI Streaming, OCI Cache for Redis (no usado en este experimento pero parte del despliegue), FastConnect simulado por VPN.

### Fase B — Generador de carga estocástico
4. **Scripts de carga con Arrival Rate** (k6 v0.53):
   - Ejecutor `ramping-arrival-rate` con módulo JavaScript que muestrea los inter-arrivals según el NHPP+MMPP definido (§4.2).
   - Extensión **xk6-distribution** para sampling de Lognormal, Pareto y Dirichlet.
   - Extensión **xk6-output-prometheus-remote-write** para emisión directa a Prometheus durante la corrida.
   - Cabecera `traceparent` propagada como atributo OpenTelemetry, con seed por iteración para reproducibilidad.

### Fase C — Observabilidad
5. **kube-prometheus-stack** desplegado en `observabilidad` con: `Prometheus`, `Alertmanager`, `Grafana`, `node-exporter`, `kube-state-metrics`.
6. **OpenTelemetry Collector** en modo daemonset, exportando trazas a Tempo o Jaeger.
7. **Dashboards de Grafana** con paneles preconfigurados:
   - *Golden Signals* del `ApiGateway` y de `CDTXPais` (rate, error, duration P50/P95/P99).
   - *USE* del `AlmacenCDTXPais` (conexiones, locks, IOPS) y del broker (lag, throughput por partición).
   - *Estados del CircuitBreaker* y count de aperturas.
   - *Gráfico de cumplimiento ASR* superpuesto al perfil de carga (visualiza el momento exacto en que P95 cruza 800 ms, si lo hace).
8. **Alertas** en Alertmanager para fallos de criterios AC-* durante la corrida.

### Fase D — Reporte y CI
9. **Pipeline reproducible** (GitHub Actions o GitLab CI) que ejecute el experimento end-to-end y publique un reporte HTML con los percentiles, gráficas y veredicto AC-* por ronda.
10. **Plantilla de reporte de hallazgos** que mapee cada `AC-*` fallido a la hipótesis arquitectónica refutada y a un ticket de rediseño.

---

## 9. Consideraciones finales

- **Reproducibilidad:** los seeds del NHPP, MMPP, Dirichlet, Lognormal y Pareto se persisten por ronda. Una falla intermitente debe poder re-ejecutarse con el mismo input estocástico.
- **No mockear la concurrencia.** El stub del core inyecta latencia y errores, pero los componentes propios de Línea Verde (ApiGateway, CDTXPais, ACL, broker) son los reales — de lo contrario el experimento prueba el modelo, no el sistema.
- **Multi-país es no negociable.** Sin el sharding por país (Dirichlet + Postgres por shard), no se prueba la propiedad central del ASR-2 sobre `AlmacenCDTXPais` y `CDTXPais` con `pais : Pais`.
- **El ASR no se prueba con un solo número.** Se prueba con la **forma** de la curva de cumplimiento bajo carga estocástica realista. El veredicto es la combinación AC-1.1, AC-2.1, AC-2.3 en N rondas — no un único promedio.

---

## 10. Material para presentación (slides)

Esta sección concentra el contenido pensado para diapositivas de la sustentación del experimento. Está diseñada para ser copiada **directamente** a slides sin reformateo.

### 10.1 Slide — Información general del experimento

> **Título sugerido:** *Validación empírica del diseño Línea Verde — ASR-1 (Latencia) y ASR-2 (Escalabilidad)*

| Eje | Definición |
|-----|-----------|
| **Producto evaluado** | Banco Z · Línea Verde · Apertura de CDT Digital de Alto Rendimiento. |
| **ASRs validados** | **ASR-1 Latencia** (P95 < 800 ms en op. normal de 800 req/h) y **ASR-2 Escalabilidad** (6.000 CDT en 20 min sin pérdida). |
| **Enfoque** | Pruebas **estocásticas** — no carga determinista. Modelo NHPP + MMPP-2 (ráfagas) + Dirichlet (sesgo por país). |
| **Alcance** | **6 componentes mínimos viables** del flujo crítico de escritura: Kong → CDTXPais → PostgreSQL → Redpanda → ACL → CoreBancoZ-stub. |
| **Plataforma** | Kubernetes 1.30 sobre **kind** en local (paridad con **OKE** en OCI). |
| **Multi-país** | 3 shards de PostgreSQL (`pe`, `mx`, `co`) — valida la promesa multi-país del diseño. |
| **Carga** | **k6 v0.53** con executor `ramping-arrival-rate` y módulo estocástico JS (xk6-distribution). |
| **Observabilidad** | Prometheus 2.55 · Grafana 11.3 · Tempo 2.6 · Loki 3.x · OpenTelemetry Collector 0.110. |
| **Ejecución** | 5 rondas independientes con seeds aleatorias, cada una de 40 min: 5 min calentamiento + 15 min línea base ASR-1 + 20 min pico ASR-2. |
| **Veredicto** | Combinación de **8 criterios** AC-1.1 a AC-2.6 — no un único promedio. Ver §7. |

**Mensajes clave para hablar (talking points):**

- El ASR no se valida con una sola medición; se valida con la **forma** de la curva de cumplimiento bajo carga estocástica realista.
- El subset mínimo elimina el ruido de componentes que no afectan la latencia del 202 ni la absorción del pico.
- La paridad **kind ↔ OKE** permite iterar el diseño en local antes de pagar tiempo en cloud.
- La separación entre **respuesta sincrónica al cliente (202 Accepted)** y la **reserva asíncrona en el core** vía outbox + broker es lo que se está poniendo a prueba.

### 10.2 Slide — Stack tecnológico (tabla compacta)

> **Título sugerido:** *Stack del experimento — paridad local ↔ OCI*

| Capa | Tecnología (local) | Versión | Equivalente en OCI |
|------|-------------------|:-------:|-------------------|
| **Lenguaje y runtime** | Java 21 LTS (Temurin) + Spring Boot + virtual threads | 21 / 3.3 | Igual (pod en OKE) |
| **Resiliencia** | Resilience4j (CircuitBreaker, Bulkhead, Retry) | 2.2 | Igual |
| **API Gateway** | Kong Gateway OSS (DB-less) | 3.7 | OCI API Gateway |
| **Mensajería** | Redpanda (Kafka API) + Apicurio Schema Registry | 24.2 / 3.0 | OCI Streaming |
| **Persistencia** | PostgreSQL + CloudNativePG (1 cluster por país) | 16.4 / 1.24 | Autonomous DB (ATP) |
| **Cluster** | kind + Kubernetes | 0.23 / 1.30 | OKE 1.30 |
| **Empaquetado** | Helm + Kustomize + Jib | 3.15 / – / 3.4 | Idem |
| **Métricas** | Prometheus + Grafana | 2.55 / 11.3 | OCI Monitoring |
| **Trazas** | OpenTelemetry Collector + Tempo | 0.110 / 2.6 | OCI APM |
| **Logs** | Loki + Promtail | 3.x | OCI Logging Analytics |
| **Generador de carga** | k6 + xk6-distribution + xk6-output-prometheus-remote-write | 0.53 | – (corre fuera del cluster productivo) |
| **IaC** | Terraform + OCI Provider | 1.9 / 6.x | – |
| **CI** | GitHub Actions | – | – |

**Notas para sustentar:**

- Cada producto local mantiene la **misma API contractual** que su par OCI (Kafka wire protocol, Postgres wire protocol, Kubernetes API). Eso preserva el realismo del experimento sin pagar OCI durante la iteración.
- La excepción intencional es `CoreBancoZ`: el real está fuera de alcance, se reemplaza por un **stub Spring Boot** que inyecta latencia Pareto y errores Bernoulli (§4.3).
- El stack es **deliberadamente conservador**: Java/Spring Boot — no Go, no Node — porque el comportamiento bajo carga (cold-start, GC, pool exhaustion) **debe ser honesto** frente a lo que un equipo bancario realmente desplegaría.
