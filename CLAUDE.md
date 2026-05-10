# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Naturaleza del repositorio

Repositorio del proyecto final del curso **ARTI 4109 - Arquitecturas de Software** (MATI - Uniandes). Combina:

1. **Documentación de arquitectura** del caso "Banco Z – Línea Verde" — diagramas, ASRs priorizados, experimento de validación, encuesta a expertos, slides de sustentación.
2. **Implementación local reproducible** del experimento de validación de ASRs — orquestada por agentes, dividida en 8 fases secuenciales con gates de avance verificables (F1 y F2 ya implementadas y versionadas).

Idioma de trabajo: **español**. Tanto los entregables como las conversaciones con el usuario se manejan en español. Nombres técnicos (clases, paquetes, etc.) van en inglés.

## Estructura

### Documentación de arquitectura (entrega académica)

- `docs/reto_final.md` — Enunciado del caso "Banco Z – Línea Verde". Contiene el contexto de negocio y los **6 comportamientos observados** que motivan los ASRs.
- `docs/ASRs.pdf` — Architecture Significant Requirements priorizados (8 ASRs: Latencia, Escalabilidad, Integración, Disponibilidad-Detección, Modificabilidad, Disponibilidad-Recuperación ×2, Seguridad). Para extraer texto: `pypdf` (instalar con `pip install --user --break-system-packages pypdf`).
- `docs/experimento_asr.md` — Diseño del experimento de validación de ASR-1 (Latencia) y ASR-2 (Escalabilidad). **Documento maestro** referenciado por los specs y agentes. Secciones clave: §3.1 (subset mínimo viable), §4 (modelo estocástico NHPP+MMPP), §5.2 (instrumentación P1–P7), §6.4 (stack consolidado), §7 (criterios AC-* del veredicto).
- `diagramas/<tipo>/` — Cada diagrama en su carpeta. Dos formatos:
  - **Estructurales y comportamentales** (`componentes`, `clases`, `despliegue`, `secuencia`) — coexisten `<tipo>.mmd` (Mermaid, importable en draw.io vía `Insert > Advanced > Mermaid`) y `<tipo>.puml` (PlantUML, para StarUML con plugin PlantUML). Opcionalmente `<tipo>_explicado.md` con tabla por subsistema.
  - **Concurrencia** (`concurrencia/`) — `.drawio` nativo, dividido en 4 archivos de fase. Sin `.mmd`/`.puml`.
- `diagramas_final/` — Versión revisada/canónica del equipo: `componentes.jpeg` (autoritativo sobre la estructura), `clases.jpeg`, `despliegue.png`. Cuando exista divergencia con `diagramas/`, gana esta carpeta.
- `encuestas/` — Encuesta de validación de ASR-3 (Facilidad de Integración): `encuesta_validacion_asr3.md` + `.xlsx` diligenciable + script generador. 10 tópicos con peso, escala 1–5, umbral > 4.0 para aprobación, 2 evaluaciones expertas.
- `slides/` — PowerPoint de sustentación: `experimento_asr1_asr2.pptx` (3 slides con diagrama del experimento) y `evaluacion_asr3.pptx` (3 slides con tópicos y modelo de 2 expertos). Reproducibles vía `python3 slides/generar_slides.py`.

Si existe el `_explicado.md`, **debe quedar sincronizado** con el `.mmd`/`.puml` cuando se modifique el diagrama.

Los cinco tipos de diagramas son: `componentes`, `clases`, `despliegue` (sobre OCI), `secuencia` (apertura de CDT + elegibilidad de Crédito Express), `concurrencia` (4 fases en draw.io).

### Implementación local (orquestación multi-agente)

- `.claude/specs/` — 9 archivos de spec por fase. `00_indice.md` gobierna el orden y la regla de gating. Cada `faseN_*.md` declara: objetivo, alcance, entradas, salidas, dependencias técnicas, pasos de implementación, **pruebas de salida (gate hacia F(N+1))** con comandos verificables, y auditoría requerida al cierre.
- `.claude/agents/` — 8 agentes Claude Code formato estándar (`name`, `description`, `model`):
  - `k8s-platform-engineer` (sonnet) — F1, F2 (manifestos K8s, Helm, NetworkPolicies, operadores)
  - `observability-engineer` (sonnet) — F3 (kube-prometheus-stack, Tempo, Loki, OTel, dashboards)
  - `spring-boot-developer` (sonnet) — F4 (Java 21 + Spring Boot 3.3 + Resilience4j)
  - `load-test-engineer` (opus) — F5 (k6 con NHPP+MMPP+Dirichlet+Pareto)
  - `performance-analyst` (opus) — F6 (percentiles, mapeo a hipótesis, veredicto AC-*)
  - `devops-ci-engineer` (sonnet) — F7 (GitHub Actions, Terraform OCI, Jib)
  - `integration-qa-engineer` (sonnet) — F8 (E2E + README final)
  - `architecture-reviewer` (opus) — transversal, audita adherencia a `componentes.jpeg`
- `infra/` — manifestos K8s, Helm values, kind config. Subdirectorios: `kind/`, `k8s/{00-namespaces,01-network-policies,02-quotas,datos,asincrono,borde}/`, `helm/{cnpg-operator,redpanda,kong,metrics-server}/`, `sql/`.
- `scripts/` — `bootstrap_cluster.sh` (F1, idempotente), `platform_bootstrap.sh` (F2), `*_teardown.sh` correspondientes.
- `tests/fN/` — `run-gates.sh` con los tests del gate de la fase N + `VERIFICACION.md` con bitácora honesta de qué se verificó dónde.
- `versions.env` — **fuente única de verdad** de las versiones del stack (sincronizado con `docs/experimento_asr.md` §6.4.10).
- `Makefile` — targets organizados por fase: `up`/`down`/`nuke` (F1), `platform-up`/`platform-down` (F2), `test-fN` (gates), `validate-manifests`. `make help` lista todo.

## Vista estructural acordada con el equipo

El diagrama de componentes fue revisado por el equipo del usuario. La vista canónica está en `diagramas/componentes/` y define **8 subsistemas** que el resto de diagramas debe respetar (los nombres son los exactos del modelo del equipo):

1. **Canales** — `AplicacionMovil`, `AplicacionWeb`.
2. **Borde** — `WAF`, `ApiGateway`, `Autorizador`.
3. **LineaVerde** — `OnboardingXPais`, `CDTXPais`, `CreditoExpressXPais`, `Pagos`, `MotorElegibilidadXPais`, `Notificaciones`.
4. **Externos** — `Convenios`, `ValidadorIdentidad`, `CoreBancoZ`, `ConsultaProveedores`.
5. **Integracion** — sub-paquete `ACL` (`AdaptadorCore`, `TraductorDominio`, `CircuitBreaker`) + `ChangeDataCapture`.
6. **Datos** — `AlmacenCDTXPais`, `AlmacenCreditoXPais`, `AlmacenPagosXPais`, `CacheDistribuido`, `ActualizadorCache`.
7. **Asincrono** — `MessageBroker` con tópicos `cdt.eventos`, `credito.eventos`, `saldo.cambios`, `eventos`.
8. **Seguridad** — `LogAuditoria`, `DetectorFraude`.

Convenciones del modelo:

- **Patrón multi-país**: el sufijo `XPais` indica una instancia por país (servicio + almacén). En el diagrama de clases se modela con `AlmacenMultiPais<T>` y el atributo `pais : Pais` en cada servicio.
- **Componentes agnósticos de tecnología**: el diagrama de **componentes** usa nombres genéricos (`MessageBroker`, `CacheDistribuido`, `Almacen*`). La selección de productos OCI vive **solo** en el diagrama de **despliegue**.

Si el usuario aporta una versión actualizada del diagrama estructural (por ejemplo `Vista estructural general.png` desde WhatsApp), está accesible desde WSL en `/mnt/c/Users/herri/AppData/Local/Packages/5319275A.WhatsAppDesktop_*/LocalState/sessions/*/transfers/`. Esa imagen es autoritativa sobre los `.mmd`/`.puml` cuando exista divergencia.

## Reglas de diseño que ya están decididas

Si modificas o agregas diagramas, respeta estas decisiones (ya alineadas con el usuario):

1. **Prioridad de ASRs**: ante conflicto, prevalecen los **3 primeros** del PDF (Latencia, Escalabilidad, Integración — los únicos con prioridad Alta o que componen el flujo crítico de apertura/elegibilidad).
2. **Anti-Corruption Layer (ACL)** entre Línea Verde y el Core Bancario compartido. El ACL es lo que permite a Línea Verde iterar en 2 semanas sin entrar al ciclo de 6-8 semanas del core.
3. **Asincronía vía MessageBroker + Outbox pattern** para responder rápido al cliente (ASR-1 < 800 ms) y absorber picos (ASR-2: 6.000 CDT/20 min). El core nunca recibe el pico directo. En despliegue, el broker se materializa como **OCI Streaming**.
4. **Consistencia de saldos (comportamiento #4 / ASR-4)**: el componente `ChangeDataCapture` (Oracle GoldenGate en despliegue) publica commits del core al broker → `ActualizadorCache` invalida/repuebla `CacheDistribuido` (OCI Cache for Redis en despliegue). Pagos críticos hacen compare-and-swap contra el core.
5. **Ventana de mantenimiento 1-4 am (ASR-6/7)**: modo degradado — consultas leen de `CacheDistribuido` (poblado por CDC); pagos se encolan en el broker y se concilian al regreso del core.
6. **Seguridad post-apertura (ASR-8)**: `DetectorFraude` consume eventos del broker, congela el CDT vía `CDTXPais.congelarCDT()` y deja evidencia en `LogAuditoria` (Object Storage WORM en despliegue) en ≤ 30 min.
7. **Infraestructura OCI obligatoria** (solo en despliegue): OKE, Autonomous DB (ATP), OCI Streaming, OCI Cache for Redis, Object Storage WORM, OCI Functions, OCI Vault, FastConnect al datacenter del banco. No proponer servicios genéricos ni de otros clouds.
8. **Mantener paridad de formato**: cualquier cambio en un diagrama debe replicarse en su par (`.mmd` ↔ `.puml`) y, si existe, en el `_explicado.md`. (No aplica a `concurrencia/`, que solo existe en `.drawio`.)
9. **No inventar componentes**: los diagramas (especialmente concurrencia) deben usar **únicamente** los componentes definidos en la vista estructural del equipo. Nombres como `OutboxDispatcher`, `Consumer Pool` o similares **no deben aparecer** — el patrón Outbox existe como decisión de implementación pero no se modela como componente separado. Si un flujo parece requerir un actor que no está en el modelo del equipo, primero confirmar con el usuario.

## Convenciones de los diagramas de concurrencia

Las 4 fases en `diagramas/concurrencia/*.drawio` siguen estas convenciones, ya alineadas con el usuario:

- **División por fases** (decisión del usuario porque una sola vista resultó "muy grande y desordenada"):
  - `fase1_apertura_cdt` — write path síncrono de apertura: Cliente → Borde Pool → Request Pool LineaVerde [CDTXPais] → ACL → CoreBancoZ + persistencia ACID + publicación al broker.
  - `fase2_proteccion_core` — close-up del ACL como bulkhead: CircuitBreaker (estados CLOSED/OPEN/HALF_OPEN) y Connection Pool acotado protegiendo al core. Callers: CDTXPais, CreditoExpressXPais, Pagos.
  - `fase3_consistencia_saldos` — read path + CDC: Cliente → Borde Pool → Request Pool [CDTXPais.consultar(), CreditoExpressXPais.elegibilidad()] → CacheDistribuido; en paralelo CDC core → broker → ActualizadorCache → CacheDistribuido.
  - `fase4_seguridad_notificaciones` — efectos secundarios async: DetectorFraude consume eventos del broker, llama síncronamente a `CDTXPais.congelarCDT()` y persiste evidencia en `LogAuditoria`; Notificaciones es stateless y hace fan-out.
- **Semántica de flechas**:
  - **Continua** = llamada síncrona (el caller espera la respuesta y bloquea su hilo).
  - **Punteada** = publicación asíncrona fire-and-forget al broker (el caller no espera al consumer).
- **Thread pools separados**: `Borde Pool` (WAF + ApiGateway + Autorizador) y `Request Pool LineaVerde` (servicios de dominio) son contenedores `«Thread»` distintos, con concurrencia independiente. Toda fase con entrada del cliente debe mostrar ambos pools encadenados.
- **Opción A (síncrona) sobre Opción B (asíncrona)**: el flujo de apertura de CDT llama al core de forma síncrona vía `ACL` (AdaptadorCore + CircuitBreaker), no vía un consumer que despache desde un tópico. Esta decisión está cerrada — no reabrir sin pedir confirmación al usuario.

## Estado de la implementación

| Fase | Estado | Spec | Bitácora de verificación |
|------|:------:|------|--------------------------|
| F1 — Bootstrap del cluster local (kind + namespaces + NetworkPolicies + quotas) | ✅ versionada | `.claude/specs/fase1_bootstrap_cluster.md` | `tests/f1/VERIFICACION.md` |
| F2 — Plataforma de datos (3 Postgres+CNPG) y mensajería (Redpanda + Apicurio + Kong DB-less) | ✅ versionada | `.claude/specs/fase2_plataforma_datos_mensajeria.md` | `tests/f2/VERIFICACION.md` |
| F3 — Observabilidad transversal | ✅ versionada | `.claude/specs/fase3_observabilidad.md` | `tests/f3/VERIFICACION.md` |
| F4 — Servicios de aplicación Spring Boot | ✅ versionada | `.claude/specs/fase4_servicios_aplicacion.md` | `tests/f4/VERIFICACION.md` |
| F5 — Generador de carga estocástico k6 | ✅ versionada | `.claude/specs/fase5_generador_carga.md` | `tests/f5/VERIFICACION.md` |
| F6 — Ejecución y análisis | ✅ versionada · EXPERIMENT PASSED 5/5 | `.claude/specs/fase6_ejecucion_analisis.md` | `tests/f6/VERIFICACION.md` |
| F7 — Reproducibilidad (CI/CD + IaC OCI) | ✅ versionada | `.claude/specs/fase7_reproducibilidad_ci.md` | `tests/f7/VERIFICACION.md` |
| F8 — Integración E2E + README | ✅ **ENTREGABLE Y REPRODUCIBLE** | `.claude/specs/fase8_integracion_e2e_y_readme.md` | `tests/f8/VERIFICACION.md` |

## Reglas operativas para continuar la implementación

1. **No saltar fases.** Cada spec declara dependencias en su sección "Bloquea a". F4 no puede iniciar sin F2; F6 no puede sin F5; etc.
2. **Gate antes de avanzar.** Después de implementar la fase N, correr `bash tests/fN/run-gates.sh`. Si cualquier prueba `BLOQUEANTE` falla, NO avanzar a F(N+1) — iterar dentro de la fase actual.
3. **Verificar antes de versionar.** El patrón establecido en F1/F2 es: build → test runtime parcial en 1-node → bitácora `tests/fN/VERIFICACION.md` honesta sobre qué se pudo y qué no → commit + push.
4. **Fixes retroactivos.** Si la fase actual descubre un bug en una anterior, corregirlo en el commit de la fase actual y mencionarlo en el commit message (ej: F2 corrigió el `default-deny` de F1 que bloqueaba intra-namespace).
5. **Adoptar la persona del agente.** Cada fase tiene un agente principal en `.claude/agents/`. Al implementar, leer el archivo del agente y operar bajo sus reglas y restricciones.
6. **Auditoría con `architecture-reviewer`.** Al cerrar cada fase, verificar mentalmente las preguntas listadas en "Auditoría requerida al cierre" del spec. Las reglas R1–R7 del reviewer (componentes.jpeg) son ley.

## Limitaciones conocidas del entorno local (WSL2)

Encontradas durante la verificación de F1 y F2 con WSL2 + Docker Desktop (cgroup v1 hybrid):

- **Multi-node kind falla**: workers no logran iniciar kubelet (`kubelet not healthy after 4m`). Workaround: cgroup v2 vía `~/.wslconfig` con `kernelCommandLine = "cgroup_no_v1=all"` + `wsl --shutdown`. F1 verificado en 1-nodo; F2 también.
- **kindnet no enforza NetworkPolicies en este entorno**: el enforcer `kube-network-policies` falla por NRI socket / nftables no disponibles. Las NPs son **estructuralmente correctas** y se enforzarán en OKE. La validación behavioral de NPs queda como `FAIL ENV` documentado, no como defecto.
- **Verificación parcial en 1-node es válida**: los manifestos correctos pueden validarse con `instances=1` (Postgres) y `replicas=1` + `RF=1` (Redpanda) como override, sin modificar los archivos versionados. Las pruebas de gate distinguen `BLOQUEANTE` de `ENV`.

## Gotchas verificados (lecciones de la implementación)

Aplicar al implementar fases siguientes — todos confirmados en runtime durante F2:

- **NetworkPolicies con `default-deny`** deben incluir un `allow-intra-namespace` por namespace. Sin ese rule, comunicación pod-a-pod dentro del mismo namespace se bloquea (rompe Apicurio→Redpanda, replicación Postgres, Kong proxy↔admin, etc.). Está aplicado en `infra/k8s/01-network-policies/00-defaults.yaml`.
- **Namespace `asincrono` requiere `pod-security.kubernetes.io/enforce: privileged`** (no `baseline`). Redpanda corre un container `tuning` con `SYS_RESOURCE` y `privileged`; sin esto el pod queda CrashLoop.
- **CloudNativePG no permite ciertos `postgresql.parameters`**: `log_destination`, `logging_collector`, `log_directory`, `data_directory` son fixed parameters que el operador gestiona. Si los pones en el `Cluster` CR, el admission webhook lo rechaza.
- **Redpanda 24.2 requiere ≥ 2 GiB de memoria container** (1 GiB es insuficiente: `seastar` reserva ~64 MB de overhead y deja menos del mínimo de 858 MB que exige). Producción también lo necesita.
- **Listener interno Kafka de Redpanda 24.2 es el puerto 9093** (no 9092). El `9092` se mapea al listener `default` para clientes externos. Servicios in-cluster (Apicurio, outbox-dispatcher, ACL en F4) deben apuntar a `redpanda.asincrono.svc.cluster.local:9093`.
- **Helm chart de Redpanda 5.9.x** cambió el schema vs versiones previas: `tolerations`, `service.type`, `statefulsetPodAntiAffinity` ya **no son top-level**. Revisar `infra/helm/redpanda/values.yaml` como referencia.
- **Kong busca declarative config en `kong.yml`** (con extensión `.yml`, no `.yaml`). El ConfigMap se monta en `/kong_dbless/` y la key del ConfigMap se convierte en filename. NO sobrescribir `KONG_DECLARATIVE_CONFIG` en `env.declarative_config` — el chart lo configura automáticamente.
- **Recursos de monitoring (`PodMonitor`, `ServiceMonitor`) requieren las CRDs de kube-prometheus-stack** que F3 instala. En F2 deben estar deshabilitados (`monitoring.podMonitorEnabled: false` en CNPG, comentar `ServiceMonitor` en Apicurio, `serviceMonitor.enabled: false` en Kong). F3 los activa con `helm upgrade`.
- **Los componentes que deshabilitan monitoring en F2** se reactivan en F3 vía `helm upgrade --reuse-values --set monitoring...=true`. NO crear archivos `*-monitor.yaml` separados — el patrón es `helm upgrade` sobre los releases existentes.
- **El componente `outbox-dispatcher` (F4) NO existe en `componentes.jpeg`**. Es detalle de implementación del patrón Outbox y debe documentarse como tal en el commit. NO añadirlo al diagrama de componentes.
- **Grafana 11.3 falla con "Only one datasource per default"** si `additionalDataSources` y `datasources` en el values de kube-prometheus-stack tienen ambos un datasource con `isDefault: true`. Poner TODOS los datasources en una sola sección `grafana.datasources.datasources.yaml` y marcar solo Prometheus como `isDefault: true`. Ver `infra/helm/kube-prometheus-stack/values.yaml`.
- **Loki 3.x en SingleBinary necesita `singleBinary.persistence.enabled: true`** en kind. Sin PVC, `/var/loki` es read-only y Loki crashea en init. La StorageClass `standard` (hostpath) de kind provisiona PVCs automáticamente. Ver `infra/helm/loki/values.yaml`.
- **La imagen otelcol-contrib es distroless** — no tiene wget, curl, ni shell. Para tests que necesiten acceder al Collector desde `kubectl exec`, usar otro pod del namespace (e.g., Grafana) que sí tenga herramientas de red.
- **Los ServiceMonitors declarativos de F3** (`kong-sm.yaml`, `redpanda-sm.yaml`, `apicurio-sm.yaml`) son equivalentes al `helm upgrade --reuse-values --set serviceMonitor.enabled=true` documentado en CLAUDE.md. En la práctica el helm upgrade de Kong falla porque el campo del chart es diferente, y el SM declarativo en `infra/k8s/observabilidad/servicemonitors/` es más robusto. Se mantiene el `helm upgrade` en el bootstrap como primer intento con fallback al SM declarativo.
