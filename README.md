# Banco Z – Línea Verde · Experimento de validación ASR-1 / ASR-2

Repositorio del proyecto final ARTI 4109 — Arquitecturas de Software (MATI - Uniandes).

Valida empíricamente **ASR-1 (Latencia < 800 ms P95)** y **ASR-2 (6.000 CDT en 20 min sin pérdida)**
del sistema Línea Verde del Banco Z. Implementación multi-agente, 8 fases secuenciales, F1–F8 validadas.

---

## 1. Resumen

Este repositorio implementa un experimento de validación de arquitectura sobre el sistema
**Línea Verde** del Banco Z — una línea de productos financieros (CDT, Crédito Express, Pagos)
orientada a clientes digitales multi-país (pe/mx/co).

El experimento valida dos ASRs críticos:

- **ASR-1 (Latencia):** la apertura de un CDT (producto de inversión) debe completarse en P95 < 800 ms
  bajo carga de línea base de 0.2 req/s por país.
- **ASR-2 (Escalabilidad):** el sistema debe procesar 6.000 aperturas de CDT en 20 minutos bajo
  tráfico pico modelado con distribución NHPP + MMPP-2, sin pérdida de transacciones.

El subconjunto mínimo viable del experimento (§3.1 del documento maestro) ejerce 6 componentes:

| Componente | Rol en el experimento |
|---|---|
| `ApiGateway` | Entrada única de tráfico k6, rate limiting, enrutamiento |
| `CDTXPais` | Servicio de apertura de CDT (instancias pe/mx/co), implementa el SLA |
| `AlmacenCDTXPais` | PostgreSQL CNPG por país, persistencia ACID de la apertura |
| `MessageBroker` | Redpanda (Kafka-compatible), absorbe eventos del Outbox Pattern |
| `ACL` | Anti-Corruption Layer hacia el Core Bancario: `AdaptadorCore` + `CircuitBreaker` |
| `CoreBancoZ` | Stub del core bancario compartido, inyecta latencia y tasa de error configurable |

El experimento usa distribuciones estocásticas reales (NHPP + MMPP-2 + Dirichlet + Lognormal + Pareto)
modeladas en k6. No usa Locust (descartado en §6.4.8) ni k3d (descartado en §6.2.1).

**Resultado:** EXPERIMENT PASSED — N=5 rondas, 8/8 AC-* aprobados.
Ver: [docs/experimento_asr.md](docs/experimento_asr.md) y `runs/results/aggregate_verdict.json`.

---

## 2. Prerrequisitos

Versiones exactas del stack. Para verificar drift entre este README y el archivo maestro:

```bash
python3 scripts/check_versions.py docs/experimento_asr.md versions.env
```

### Software requerido

| Herramienta | Versión mínima | Instalación |
|---|---|---|
| Docker Desktop | 27.x | https://docs.docker.com/desktop/ |
| kind | v0.23 | `go install sigs.k8s.io/kind@v0.23.0` o release binario |
| kubectl | v1.30 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | v3.15 | https://helm.sh/docs/intro/install/ |
| JDK 21 (Temurin) | 21 | https://adoptium.net/ |
| Python | 3.12 | https://www.python.org/downloads/ |
| k6 | v0.53 | https://grafana.com/docs/k6/latest/set-up/install-k6/ |
| Terraform | 1.9 | https://developer.hashicorp.com/terraform/install (solo para OCI) |
| gh CLI | 2.x | https://cli.github.com/ (solo para CI/CD) |

### Recursos mínimos de hardware

| Recurso | Mínimo | Recomendado |
|---|---|---|
| RAM | 12 GiB libres para Docker | 16 GiB |
| CPU | 4 núcleos | 6 núcleos |
| Disco | 10 GiB libres | 20 GiB |

**WSL2:** si corres en Windows con WSL2, añade a `~/.wslconfig`:
```ini
[wsl2]
memory=12GB
processors=4
kernelCommandLine = "cgroup_no_v1=all"
```
Luego `wsl --shutdown` y reiniciar Docker Desktop.

### Verificar prerrequisitos

```bash
docker info | grep "Total Memory"
kind version
kubectl version --client
helm version --short
java --version
python3 --version
k6 version
```

---

## 3. Estructura del repositorio

```
.
├── docs/
│   ├── experimento_asr.md     # Documento maestro del experimento
│   └── ASRs.pdf               # 8 ASRs priorizados (Latencia, Escalabilidad, ...)
├── diagramas_final/
│   ├── componentes.jpeg       # Vista estructural canónica (autoritativa)
│   ├── clases.jpeg            # Diagrama de clases
│   └── despliegue.png         # Diagrama de despliegue OCI
├── .claude/
│   ├── specs/                 # Specs de las 8 fases (00_indice.md + fase1..fase8)
│   └── agents/                # Agentes Claude Code por fase
├── infra/
│   ├── kind/                  # Configuración del cluster kind
│   ├── k8s/                   # Manifiestos Kubernetes por subsistema
│   ├── helm/                  # Helm values por chart (cnpg, redpanda, kong, ...)
│   ├── sql/                   # Scripts DDL para las 3 bases de datos
│   └── terraform/             # Módulos IaC para OCI (F7)
├── services/
│   ├── cdt-pais/              # CDTXPais — Spring Boot 3.3, Java 21
│   ├── acl/                   # ACL (AdaptadorCore + CircuitBreaker) — Spring Boot 3.3
│   ├── outbox-dispatcher/     # Detalle de impl. Outbox Pattern (no es componente del diagrama)
│   └── core-stub/             # CoreBancoZ stub — Spring Boot 3.3
├── load/
│   ├── scenarios/             # Scripts k6: warmup.js, baseline_asr1.js, peak_asr2.js
│   ├── lib/                   # Librería NHPP + MMPP-2 + Dirichlet + Lognormal + Pareto
│   └── test/                  # Tests de validación del modelo estocástico
├── runs/
│   ├── run_round.py           # Orquestador de una ronda (F6)
│   ├── aggregate_results.py   # Agrega N rondas en veredicto único
│   ├── lib/                   # PrometheusClient, verdicts, manifest, ...
│   └── results/               # Resultados de rondas y veredicto agregado
├── report/                    # Generador de reportes HTML
├── scripts/                   # Scripts de bootstrap/teardown por fase + validadores F8
├── tests/
│   ├── f1/ ... f8/            # Gates por fase (run-gates.sh + VERIFICACION.md)
├── versions.env               # Fuente única de verdad de versiones
└── Makefile                   # Targets organizados por fase
```

---

## 4. Inicio rápido (3 comandos)

```bash
make up          # Bootstrap completo: cluster kind + plataforma + observabilidad + servicios (F1–F4)
make experiment  # Corrida smoke del experimento: 1 ronda (F5+F6). ~15 min.
make report      # Genera reporte HTML y lo abre en el navegador
```

El target `make up` es idempotente: si el cluster ya existe, no lo recrea.

Para el smoke E2E completo de F8 (verifica reproducibilidad desde estado limpio):

```bash
make nuke && make e2e-short   # Destruye cluster y corre smoke E2E desde cero (~27 min)
```

---

## 5. Operación detallada por fase

### F1 — Bootstrap del cluster

```bash
make up        # Crea cluster kind + namespaces + NetworkPolicies + ResourceQuotas
make down      # Elimina el cluster kind
make nuke      # Alias de make down (compatibilidad con specs)
make test-f1   # Gate F1: 9 tests BLOQUEANTE
```

Verifica: `kind get clusters` debe mostrar `linea-verde`.
Ver spec: [.claude/specs/fase1_bootstrap_cluster.md](.claude/specs/fase1_bootstrap_cluster.md)

### F2 — Plataforma de datos y mensajería

```bash
make platform-up    # Despliega 3 Postgres CNPG + Redpanda + Apicurio + Kong DB-less
make platform-down  # Desmonta F2 (deja F1 intacta)
make test-f2        # Gate F2: 11 tests BLOQUEANTE
```

Verifica: `kubectl get pods -n datos` y `kubectl get pods -n asincrono` deben mostrar Running.
Ver spec: [.claude/specs/fase2_plataforma_datos_mensajeria.md](.claude/specs/fase2_plataforma_datos_mensajeria.md)

### F3 — Observabilidad transversal

```bash
make observability-up    # kube-prometheus-stack + Tempo + Loki + OTel Collector + dashboards
make observability-down  # Desmonta F3 (deja F1+F2 intactos)
make test-f3             # Gate F3: 10 tests BLOQUEANTE
```

Grafana disponible en: `kubectl port-forward -n observabilidad svc/kube-prometheus-stack-grafana 3000:80`
Ver spec: [.claude/specs/fase3_observabilidad.md](.claude/specs/fase3_observabilidad.md)

### F4 — Servicios de aplicación Spring Boot

```bash
make services-build   # Compila 4 imágenes con Jib y las carga al cluster
make services-deploy  # Aplica deployments, HPA, ServiceMonitors
make services-down    # Borra deployments F4
make test-f4          # Gate F4: 13 tests BLOQUEANTE
```

Ver spec: [.claude/specs/fase4_servicios_aplicacion.md](.claude/specs/fase4_servicios_aplicacion.md)

### F5 — Generador de carga estocástico k6

```bash
make load-build          # Bundle JS + build imagen k6 + kind load
make load-deploy         # Despliega k6-operator + ConfigMaps + RBAC
make validate-load-model # Valida el modelo estocástico (6 tests JS standalone)
make test-f5             # Gate F5: 12 tests BLOQUEANTE
```

Ver spec: [.claude/specs/fase5_generador_carga.md](.claude/specs/fase5_generador_carga.md)

### F6 — Ejecución y análisis

```bash
make f6-round            # 1 ronda (SEED=42 MODE=smoke|scaled|full)
make f6-rounds           # 5 rondas (seeds 42..46)
make f6-aggregate        # Agrega rondas en veredicto único
make f6-report           # Abre el último reporte HTML
make test-f6             # Gate F6: 10 tests BLOQUEANTE
```

El veredicto autoritativo requiere `MODE=full` (warmup 5m + baseline 15m + peak 20m por ronda,
N=5 rondas ≈ 3.5 h). Ver: [docs/experimento_asr.md](docs/experimento_asr.md) §7.
Ver spec: [.claude/specs/fase6_ejecucion_analisis.md](.claude/specs/fase6_ejecucion_analisis.md)

### F7 — Reproducibilidad CI/CD y OCI

```bash
make tf-validate   # terraform validate + tflint en todos los módulos
make tf-plan       # Lanza plan vía GitHub Actions (requiere credenciales OCI)
make tf-apply      # Lanza apply vía workflow_dispatch
make helm-lint     # helm lint del chart lv-experiment
make check-versions # Verifica drift entre versions.env y §6.4.10
make test-f7       # Gate F7: 12 tests (9 PASS, 3 FAIL ENV en local)
```

Ver spec: [.claude/specs/fase7_reproducibilidad_ci.md](.claude/specs/fase7_reproducibilidad_ci.md)

---

## 6. Pruebas manuales por componente

Smoke tests individuales para cada componente del subset mínimo viable (§3.1).
Todos los comandos asumen que el stack está corriendo (`make up` completado) y
que el port-forward de Kong está activo:

```bash
kubectl port-forward -n borde svc/kong-kong-proxy 8090:80 &
```

### ApiGateway (Kong DB-less)

Verifica que Kong responde en el puerto proxy y en el admin:

```bash
# Health check del proxy
curl -s http://localhost:8090/healthz

# Admin API (desde dentro del cluster)
kubectl exec -n borde deploy/kong-kong -c proxy -- \
  curl -s http://localhost:8001/status | python3 -m json.tool | grep '"database"'
```

Resultado esperado: HTTP 200 en proxy; `"reachability": true` en admin status.

### CDTXPais (apertura de CDT)

```bash
curl -s -X POST http://localhost:8090/v1/cdt \
  -H "Content-Type: application/json" \
  -H "X-Country: pe" \
  -d '{"clientId":"c-001","amount":5000,"currency":"PEN","termDays":180}' \
  | python3 -m json.tool
```

Resultado esperado: HTTP 202 con body `{"cdtId":"<UUID v4>","status":"PROCESSING"}`.

### AlmacenCDTXPais (Postgres CNPG)

```bash
# Obtener password del secret
PGPASSWORD=$(kubectl get secret postgres-pe-app -n datos \
  -o jsonpath='{.data.password}' | base64 -d)

# Contar CDTs persistidos en la base del país PE
kubectl exec -n datos postgres-pe-1 -- \
  psql -U app -d linea_verde \
  -c "SELECT count(*) FROM cdts WHERE status = 'PROCESSING';" 2>/dev/null
```

Resultado esperado: count >= 1 si se ejecutó el POST anterior.

### MessageBroker (Redpanda)

```bash
# Consumir los últimos 5 eventos del tópico cdt.eventos
kubectl exec -n asincrono redpanda-0 -- \
  rpk topic consume cdt.eventos \
    --brokers localhost:9093 \
    --offset -5 \
    --num 5 \
    --fetch-max-wait 5s 2>/dev/null | python3 -m json.tool
```

Resultado esperado: JSON con campo `"eventType":"CDT_ABIERTO"` por cada apertura reciente.

### ACL (AdaptadorCore + CircuitBreaker)

```bash
# Verificar estado del CircuitBreaker (debe estar CLOSED en condiciones normales)
kubectl exec -n linea-verde \
  $(kubectl get pod -n linea-verde -l app=acl -o jsonpath='{.items[0].metadata.name}') -- \
  curl -s http://localhost:8080/actuator/prometheus 2>/dev/null \
  | grep 'resilience4j_circuitbreaker_state{name="coreCall",state="closed"}'
```

Resultado esperado: `resilience4j_circuitbreaker_state{...,state="closed"} 1.0`.
Si el CB está OPEN: el core-stub puede estar retornando errores — ver §8 Troubleshooting.

### CoreBancoZ (stub)

```bash
# Llamada directa con 0% error rate
kubectl exec -n linea-verde \
  $(kubectl get pod -n linea-verde -l app=acl -o jsonpath='{.items[0].metadata.name}') -- \
  curl -s -X POST http://core-stub.linea-verde.svc.cluster.local:8080/v1/core/cdt \
    -H "Content-Type: application/json" \
    -H "X-Stub-Error-Rate: 0.0" \
    -d '{"clientId":"c-001","amount":5000}'
```

Resultado esperado: HTTP 200 con `{"coreRef":"<UUID>","status":"BOOKED"}`.

---

## 7. Interpretación del reporte

El reporte HTML (`runs/results/<round_id>/report.html`) tiene cuatro secciones:

### 7.1 Veredicto de la ronda

Banner verde (PASS) o rojo (FAIL/ERROR) con el veredicto global de la ronda.
Los modos `smoke` y `scaled` y `e2e-short` no son autoritativos — el banner
incluye el aviso "SMOKE — no autoritativo".

### 7.2 Tabla de AC-* individuales

| Columna | Significado |
|---|---|
| AC-* | Identificador del criterio de aceptación (§7 del documento maestro) |
| Veredicto | PASS / FAIL / NA / ERROR |
| Valor | Métrica observada (e.g., P95=9.5 ms, volumen=839) |
| Umbral | Criterio del §7 (e.g., < 800 ms, >= 6000) |
| Hipótesis | Referencia a §4.4 si FAIL |

- **AC-1.1:** P95 de latencia en línea base estratificado por país (umbral 800 ms).
- **AC-1.2:** P99 de latencia en línea base (umbral 1500 ms).
- **AC-2.1:** Volumen total de aperturas en el pico (umbral 6000 en modo full; proporcional en escalado).
- **AC-2.2:** Aperturas perdidas (umbral 0).
- **AC-2.3:** Minutos en el pico donde P95 < 800 ms (umbral >= 18/20 min).
- **AC-2.4:** Mensajes huérfanos en el broker (umbral 0 via invariante outbox).
- **AC-2.5:** HPA escala a >= 3 réplicas bajo pico (NA si carga insuficiente para gatillar HPA).
- **AC-2.6:** CircuitBreaker no abre durante la ronda (umbral: 0 transiciones CLOSED→OPEN).

### 7.3 Percentiles estratificados por país

Gráficas SVG inline de P95/P99 por país (pe/mx/co) durante baseline y peak.
Si faltan gráficas: el snapshot Prometheus está vacío — ver §8.

### 7.4 Coordinated Omission

Ratio observado/objetivo para baseline y peak. Si ratio < 0.85 la ronda se
marca INVALID y no cuenta para el agregado.

### 7.5 Reporte agregado N=5

`runs/results/aggregate.html` muestra medias y desvíos de P95/P99 sobre las N rondas.
El campo `experiment_status` en `aggregate_verdict.json` es el veredicto final:
`EXPERIMENT_PASSED` o `EXPERIMENT_FAILED`.

---

## 8. Solución de problemas

Escenarios reales encontrados durante la implementación de F1–F8 en WSL2.

### Problema 1: cluster kind no arranca con múltiples nodos (WSL2 cgroup v1)

**Síntoma:** `kubectl get nodes` muestra workers en `NotReady`; logs con `kubelet not healthy after 4m`.

**Causa:** WSL2 usa cgroup v1 híbrido por defecto. kind multi-node falla porque los workers
no pueden iniciar kubelet bajo esta configuración.

**Solución:**
```ini
# ~/.wslconfig
[wsl2]
kernelCommandLine = "cgroup_no_v1=all"
memory=12GB
```
Luego: `wsl --shutdown` y reiniciar Docker Desktop. El experimento usa 1 nodo (control-plane only).

### Problema 2: NetworkPolicies de kind no se aplican (WSL2 + kindnet)

**Síntoma:** pods de namespaces diferentes se comunican aunque exista un `NetworkPolicy` deny.

**Causa:** el enforcer `kube-network-policies` falla en WSL2 por socket NRI / nftables no disponibles.

**Solución:** las NetworkPolicies son estructuralmente correctas y se aplican en OKE.
En local el experimento funciona sin enforcement de NP. Este es un `FAIL ENV` documentado,
no un defecto del experimento.

### Problema 3: Redpanda CrashLoop por memoria insuficiente

**Síntoma:** `kubectl get pods -n asincrono` muestra `CrashLoopBackOff` en el pod de Redpanda.

**Causa:** Redpanda 24.2 requiere >= 2 GiB de memoria de container. Con 1 GiB, el framework
`seastar` reserva ~64 MB de overhead y deja menos del mínimo requerido de 858 MB.

**Solución:** verificar que Docker Desktop tiene >= 8 GiB asignados. El values de Redpanda
en `infra/helm/redpanda/values.yaml` ya tiene `resources.limits.memory: "2Gi"`.
Si Docker tiene < 8 GiB, reducir otras cargas o aumentar en Docker Desktop > Settings > Resources.

### Problema 4: ACL no se conecta a Redpanda (puerto 9092 vs 9093)

**Síntoma:** `outbox-dispatcher` logs muestran `Connection refused` o `LEADER_NOT_AVAILABLE`.

**Causa:** Redpanda 24.2 asigna el listener interno Kafka al **puerto 9093**, no 9092.
El puerto 9092 está mapeado al listener `default` para clientes externos al cluster.
Servicios in-cluster (`outbox-dispatcher`, `ACL`) deben usar `redpanda.asincrono.svc.cluster.local:9093`.

**Solución:** verificar en `infra/k8s/asincrono/` que `KAFKA_BROKERS` apunta a `:9093`.
El error es silencioso si el topic existe pero el producer conecta al listener equivocado.

### Problema 5: Kong no carga la configuración declarativa (kong.yml vs kong.yaml)

**Síntoma:** Kong arranca pero todas las rutas retornan 404. Logs: `declarative config file not found`.

**Causa:** Kong busca el archivo `kong.yml` (extensión `.yml`). Si el ConfigMap usa key `kong.yaml`,
Kong no lo encuentra en `/kong_dbless/kong.yaml` — busca `/kong_dbless/kong.yml`.

**Solución:** verificar que el key del ConfigMap es `kong.yml` (con `.yml`):
```bash
kubectl get configmap -n borde kong-kong-dbless-config -o yaml | grep "kong\."
```
Si muestra `kong.yaml`, aplicar `infra/k8s/borde/kong-config.yaml` que usa la key correcta.

### Problema 6: CircuitBreaker nunca abre (Resilience4j + Spring Boot 3.x)

**Síntoma:** el test T-7 del gate F4 reporta que el CB no llega a estado `open` aunque se inyecten
errores al core-stub.

**Causa:** si `fallbackMethod` está declarado en `@Retry` además de en `@CircuitBreaker`, el CB
ve el método como exitoso (el fallback es un éxito desde la perspectiva del Retry) y no acumula
fallos para abrir.

**Solución:** declarar `fallbackMethod` SOLO en `@CircuitBreaker`. El `@Retry` debe propagar la
excepción al `@CircuitBreaker`. Ver `services/acl/src/main/java/.../ResilientCoreClient.java`.

### Problema 7: Spring Boot no expone buckets del histograma (MetricsConfig @PostConstruct)

**Síntoma:** `/actuator/prometheus` de `CDTXPais` expone buckets genéricos `1e-11, 2.5e-11, ...`
en lugar de los SLOs del experimento (`le=0.8`, `le=1.5`).

**Causa:** el `MeterFilter` con SLOs registrado en `@PostConstruct` corre DESPUÉS de que Spring
auto-configura los `@Timed` Timers. Los Timers nacen sin los SLOs correctos.

**Solución:** registrar el filter como `MeterRegistryCustomizer<MeterRegistry>` (bean que Spring
Boot aplica antes de cualquier Timer). Ver `services/cdt-pais/src/main/java/.../MetricsConfig.java`.

### Problema 8: PostgreSQL JDBC rechaza java.time.Instant

**Síntoma:** `POST /v1/cdt` falla con `PSQLException: Can't infer the SQL type for java.time.Instant`.

**Causa:** el driver PostgreSQL JDBC no infiere automáticamente el tipo SQL para `java.time.Instant`.

**Solución:** envolver con `Timestamp.from(instant)` antes de pasar a la query:
```java
stmt.setTimestamp(idx, Timestamp.from(cdt.getCreatedAt()));
```

### Problema 9: Grafana 11.3 falla con "Only one datasource per default"

**Síntoma:** Grafana crashea en startup con error `Only one datasource per default`.

**Causa:** si tanto `additionalDataSources` como `datasources` en el values de kube-prometheus-stack
tienen un datasource con `isDefault: true`, Grafana lo rechaza.

**Solución:** poner TODOS los datasources en una sola sección `grafana.datasources.datasources.yaml`
y marcar solo Prometheus como `isDefault: true`. Ver `infra/helm/kube-prometheus-stack/values.yaml`.

### Problema 10: Loki crashea en init (SingleBinary sin PVC)

**Síntoma:** `kubectl get pods -n observabilidad` muestra Loki en `Init:Error` o `CrashLoopBackOff`.
Logs: `permission denied: /var/loki`.

**Causa:** Loki 3.x en modo SingleBinary necesita `singleBinary.persistence.enabled: true` en kind.
Sin PVC, `/var/loki` es un directorio read-only del container.

**Solución:** verificar `infra/helm/loki/values.yaml` tiene `persistence.enabled: true`.
La StorageClass `standard` (hostpath) de kind provisiona PVCs automáticamente.

### Problema 11: make services-build falla — registry connection refused

**Síntoma:** `docker push kind-registry:5000/...` falla con `connection refused`.

**Causa:** el registry in-cluster de kind no está corriendo o el cluster no existe.

**Diagnóstico y solución:**
```bash
kind get clusters          # verificar que existe 'linea-verde'
docker ps | grep registry  # verificar container kind-registry
```
Si el cluster no existe: `make up` primero.
Si el registry no responde: `docker restart kind-registry`.

---

## 9. Migración a OCI

Para desplegar el experimento en Oracle Cloud Infrastructure (OCI) en lugar del cluster kind local:

### 9.1 Prerrequisitos OCI

- Tenant OCI con permisos de administrador del compartment
- API Key: `~/.oci/oci_api_key.pem` y `~/.oci/config`
- Secrets de GitHub configurados en el repositorio:
  `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY`,
  `OCI_REGION`, `OCI_COMPARTMENT_OCID`, `OCIR_TENANCY_NAMESPACE`,
  `OCIR_REGION`, `OCIR_USER_EMAIL`, `OCIR_PASSWORD`

### 9.2 Plan y Apply (via GitHub Actions)

El plan se lanza automáticamente en cualquier PR que modifique `infra/terraform/**`:

```bash
# Plan manual
make tf-plan

# Apply (lanza workflow vía gh CLI)
make tf-apply DB_ENGINE=postgres TTL_HOURS=24
```

La infraestructura se destruye automáticamente tras 24 h (TTL configurable).
Para desactivar el destroy automático: `SKIP_DESTROY=true`.

### 9.3 Motor de base de datos (§6.4.11 del documento maestro)

Por defecto `db_engine = "postgres"` (OCI Database with PostgreSQL) — drop-in compatible
con el experimento local, sin cambios en drivers JDBC ni dialecto Hibernate.

Para activar Autonomous Database (ATP): `make tf-apply DB_ENGINE=atp`

Esto se justifica únicamente si Cumplimiento exige ATP (cifrado at-rest gestionado,
Data Safe, etc.). Requiere migración del driver JDBC a `ojdbc11` y dialecto
`OracleDialect` en Spring Boot. Ver `infra/terraform/db/README.md` y §6.4.11 Matiz 3.

### 9.4 Módulos Terraform

| Módulo | Recursos OCI |
|---|---|
| `infra/terraform/networking/` | VCN multi-AD, subnets, NAT Gateway, FastConnect DRG |
| `infra/terraform/iam/` | Compartment, dynamic groups, policies |
| `infra/terraform/oke/` | OKE 1.30, node pool E5.Flex autoscaling 3–12 nodos |
| `infra/terraform/db/` | OCI DB with PostgreSQL (default) o ATP |
| `infra/terraform/streaming/` | OCI Streaming + tópico `cdt.eventos` |
| `infra/terraform/registry/` | OCIR con repositorios por servicio |

### 9.5 Deploy en OKE con Helm

```bash
# Obtener kubeconfig de OKE
oci ce cluster create-kubeconfig --cluster-id <oke_cluster_id> --file ~/.kube/config

# Instalar el chart unificado con values OCI
helm install lv-experiment infra/helm/lv-experiment \
  -f infra/helm/lv-experiment/values-oci.yaml \
  --set image.registry=<region>.ocir.io \
  --set image.organization=<namespace>/lv-experiment/linea-verde
```

---

## 10. Referencias

### Documentación del experimento

- [docs/experimento_asr.md](docs/experimento_asr.md) — Documento maestro: diseño del experimento,
  modelo estocástico (§4), instrumentación (§5), stack técnico (§6), criterios AC-* (§7).
- `docs/ASRs.pdf` — 8 ASRs priorizados del sistema Línea Verde.

### Diagramas arquitectónicos (vista canónica)

- [diagramas_final/componentes.jpeg](diagramas_final/componentes.jpeg) — Vista estructural canónica
  (autoritativa sobre los 8 subsistemas y sus componentes).
- [diagramas_final/clases.jpeg](diagramas_final/clases.jpeg) — Diagrama de clases con patrón multi-país.
- [diagramas_final/despliegue.png](diagramas_final/despliegue.png) — Despliegue sobre OCI.

### Specs de las 8 fases

- [.claude/specs/fase1_bootstrap_cluster.md](.claude/specs/fase1_bootstrap_cluster.md)
- [.claude/specs/fase2_plataforma_datos_mensajeria.md](.claude/specs/fase2_plataforma_datos_mensajeria.md)
- [.claude/specs/fase3_observabilidad.md](.claude/specs/fase3_observabilidad.md)
- [.claude/specs/fase4_servicios_aplicacion.md](.claude/specs/fase4_servicios_aplicacion.md)
- [.claude/specs/fase5_generador_carga.md](.claude/specs/fase5_generador_carga.md)
- [.claude/specs/fase6_ejecucion_analisis.md](.claude/specs/fase6_ejecucion_analisis.md)
- [.claude/specs/fase7_reproducibilidad_ci.md](.claude/specs/fase7_reproducibilidad_ci.md)
- [.claude/specs/fase8_integracion_e2e_y_readme.md](.claude/specs/fase8_integracion_e2e_y_readme.md)

### Agentes Claude Code

- [.claude/agents/k8s-platform-engineer.md](.claude/agents/k8s-platform-engineer.md) — F1, F2
- [.claude/agents/observability-engineer.md](.claude/agents/observability-engineer.md) — F3
- [.claude/agents/spring-boot-developer.md](.claude/agents/spring-boot-developer.md) — F4
- [.claude/agents/load-test-engineer.md](.claude/agents/load-test-engineer.md) — F5
- [.claude/agents/performance-analyst.md](.claude/agents/performance-analyst.md) — F6
- [.claude/agents/devops-ci-engineer.md](.claude/agents/devops-ci-engineer.md) — F7
- [.claude/agents/integration-qa-engineer.md](.claude/agents/integration-qa-engineer.md) — F8
- [.claude/agents/architecture-reviewer.md](.claude/agents/architecture-reviewer.md) — transversal

### Estado del experimento

| Fase | Estado | Bitácora |
|---|:---:|---|
| F1 — Bootstrap cluster (kind + NS + NP + quotas) | OK | `tests/f1/VERIFICACION.md` |
| F2 — Plataforma (3 Postgres + Redpanda + Apicurio + Kong) | OK | `tests/f2/VERIFICACION.md` |
| F3 — Observabilidad (Prometheus + Tempo + Loki + OTel) | OK | `tests/f3/VERIFICACION.md` |
| F4 — Servicios Spring Boot 3.3 / Java 21 | OK | `tests/f4/VERIFICACION.md` |
| F5 — Generador k6 (NHPP + MMPP-2 + Dirichlet) | OK | `tests/f5/VERIFICACION.md` |
| F6 — Ejecución N=5, EXPERIMENT PASSED, 8/8 AC-* | OK | `tests/f6/VERIFICACION.md` |
| F7 — CI/CD GitHub Actions + Terraform OCI | OK | `tests/f7/VERIFICACION.md` |
| F8 — Integración E2E + README (este archivo) | OK | `tests/f8/VERIFICACION.md` |

**Nota sobre `outbox-dispatcher`:** el servicio `outbox-dispatcher` implementa el
[Outbox Pattern](https://microservices.io/patterns/data/transactional-outbox.html) como detalle
de implementación de la persistencia de eventos. No aparece en el diagrama de componentes
`diagramas_final/componentes.jpeg` porque es un artefacto de implementación, no un componente
arquitectónico del modelo del equipo.
