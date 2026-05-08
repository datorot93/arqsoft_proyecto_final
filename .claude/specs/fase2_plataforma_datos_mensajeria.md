# Fase 2 — Plataforma de datos y mensajería

**Agente principal:** `k8s-platform-engineer`
**Documento maestro:** `docs/experimento_asr.md` §6.4.3, §6.4.4, §6.4.5
**Bloquea a:** F4 (servicios necesitan DB y broker), F5 (broker objetivo)
**Modelo sugerido:** sonnet

## Objetivo

Desplegar los componentes de plataforma que el experimento usa pero **no implementa**: persistencia (`AlmacenCDTXPais`), mensajería (`MessageBroker`) y borde (`ApiGateway`). Quedan disponibles a las fases siguientes con la misma topología que en producción (multi-país para Postgres, Kafka API para el broker).

## Alcance

### Persistencia (`AlmacenCDTXPais`)
- **3 clusters PostgreSQL 16.4** vía operador **CloudNativePG 1.24**, uno por país: `pe`, `mx`, `co`.
- Cada cluster: 1 primary + 1 standby (HA local). PVC en StorageClass `standard` (host-path en kind).
- Schema `cdt` con tablas `cdt` y `outbox_cdt_eventos`. Definidas vía `Cluster.spec.bootstrap.initdb.postInitApplicationSQL`.
- HikariCP pool: dimensionamiento decidido en F4 (no en esta fase).

### Mensajería (`MessageBroker`)
- **Redpanda 24.2** vía Redpanda Operator. 3 brokers, replication factor=3.
- Tópico `cdt.eventos` con **6 particiones** (≥ países × 2 para evitar hot-partition por país).
- Tópico `cdt.eventos.DLQ` con retención 7 días.
- **Apicurio Registry 3.0** como Schema Registry, modo de compatibilidad `BACKWARD`.
- Otros tópicos del modelo (`saldo.cambios`, `credito.eventos`, `eventos`) **no** se crean en esta fase (fuera del subset mínimo viable §3.1).

### Borde (`ApiGateway`)
- **Kong Gateway 3.7 OSS** en modo DB-less (config declarativa `kong.yml`).
- Plugins activos: `rate-limiting-advanced`, `request-size-limiting`, `correlation-id`, `prometheus`, `opentelemetry`.
- Throttling adaptativo configurable; valor default 60 req/s con burst de 50.
- Servicios upstream apuntan a los 3 deployments de `CDTXPais` por país (cuando F4 los desplegue).

## Entradas

- F1 completada: cluster kind con namespaces y NetworkPolicies.
- `docs/experimento_asr.md` §6.4.3, §6.4.4, §6.4.5 para versiones y configuración.
- Tópicos del modelo en `componentes.jpeg` subsistema `Asincrono`.

## Salidas (artefactos)

| Artefacto | Ruta sugerida |
|-----------|---------------|
| Helm values de CloudNativePG | `infra/helm/cnpg-operator/values.yaml` |
| `Cluster` CRDs por país | `infra/k8s/datos/cluster-{pe,mx,co}.yaml` |
| Bootstrap SQL (schemas y tablas) | `infra/sql/01-init-cdt.sql`, `02-init-outbox.sql` |
| Helm values de Redpanda Operator | `infra/helm/redpanda/values.yaml` |
| `Topic` CRDs (`cdt.eventos`, DLQ) | `infra/k8s/asincrono/topics.yaml` |
| Apicurio Registry deployment | `infra/k8s/asincrono/apicurio.yaml` |
| Kong DB-less manifest + ConfigMap `kong.yml` | `infra/k8s/borde/` |
| `make platform-up` / `platform-down` | `Makefile` |

## Dependencias técnicas

| Componente | Versión | Helm chart |
|-----------|:-------:|-----------|
| CloudNativePG operator | 1.24 | `cnpg/cloudnative-pg` |
| PostgreSQL | 16.4 | (imagen `ghcr.io/cloudnative-pg/postgresql:16.4`) |
| Redpanda Operator | latest compatible con Redpanda 24.2 | `redpanda/operator` |
| Redpanda | 24.2 | – |
| Apicurio Registry | 3.0 | manifest oficial |
| Kong Gateway OSS | 3.7 | `kong/kong` (mode `dbless`) |

## Pasos de implementación (alto nivel)

1. Instalar operadores en `cluster-system` namespace: CloudNativePG, Redpanda Operator.
2. Crear los 3 `Cluster` CRDs en namespace `datos` con bootstrap SQL que cree schema `cdt`, tabla `cdt`, tabla `outbox_cdt_eventos` con índice por `published_at IS NULL` (para el dispatcher).
3. Verificar replicación local: insertar fila en primary, leerla en standby.
4. Crear el cluster Redpanda en namespace `asincrono` con 3 brokers, RF=3, tópicos `cdt.eventos` (6 particiones) y `cdt.eventos.DLQ`.
5. Desplegar Apicurio Registry y conectar al broker.
6. Desplegar Kong DB-less con `kong.yml` declarando un service stub que apunte a `cdt-pais-pe.linea-verde.svc.cluster.local` (aún sin upstream real; F4 lo provisiona).
7. Aplicar `ServiceMonitor` para Kong y para Redpanda (la observabilidad real se configura en F3, pero los `ServiceMonitor` se dejan listos).

## Criterios de éxito

| ID | Criterio | Cómo verificar |
|----|---------|----------------|
| F2.AC-1 | 3 clusters Postgres `Ready`. | `kubectl get clusters.postgresql.cnpg.io -A` muestra `pe`, `mx`, `co` con `STATUS=Cluster in healthy state`. |
| F2.AC-2 | Schemas `cdt.cdt` y `cdt.outbox_cdt_eventos` existen. | `psql -c "\dt cdt.*"` desde un pod en cada cluster. |
| F2.AC-3 | Redpanda tópico `cdt.eventos` con 6 particiones, RF=3. | `rpk topic describe cdt.eventos` reporta los valores. |
| F2.AC-4 | Apicurio Registry alcanzable desde `linea-verde`. | `curl http://apicurio.asincrono.svc:8080/apis/registry/v3/` retorna 200. |
| F2.AC-5 | Kong DB-less responde en healthcheck. | `curl -s http://kong-admin.borde.svc:8001/status` retorna `database.reachable: false` y `server.connections_handled > 0`. |

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|------------|
| Sobrecarga de recursos en kind con 3 Postgres | `resources.limits` por cluster: 1 CPU / 1 GB RAM. Documentar requisito de 16 GB host. |
| Drift de versión de Postgres con CNPG | Pinneado en `Cluster.spec.imageName`. CI valida coincidencia. |
| Tópicos faltantes en runtime | Job post-deploy que valida con `rpk topic list` y falla si `cdt.eventos` no existe. |
| Bypass del ACL hacia Postgres del país equivocado | NetworkPolicy de F1 prohíbe que `cdt-pais-mx` lea de `postgres-pe`. |

## Pruebas de salida (gate hacia F3)

> **Regla del gate:** TODAS las pruebas marcadas `BLOQUEANTE` deben pasar antes de iniciar F3. Si una falla, NO se avanza.

| ID | Prueba | Comando concreto | Resultado esperado | Gate |
|----|--------|------------------|--------------------|:----:|
| F2.T-1 | 3 clusters Postgres healthy | `kubectl get clusters.postgresql.cnpg.io -n datos -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{"\n"}{end}'` | 3 líneas: `postgres-pe=Cluster in healthy state`, idem mx, co | BLOQUEANTE |
| F2.T-2 | Schema `cdt` en cada país | `kubectl exec -n datos postgres-{pe,mx,co}-1 -- psql -U postgres -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='cdt';"` | `≥ 2` en los 3 (tablas `cdt` y `outbox_cdt_eventos`) | BLOQUEANTE |
| F2.T-3 | Replicación primary→standby | `INSERT` en primary y `SELECT` en standby vía `kubectl exec` | fila visible en standby en menos de 1 s | BLOQUEANTE |
| F2.T-4 | Tópico `cdt.eventos` con 6 particiones, RF=3 | `kubectl exec -n asincrono redpanda-0 -c redpanda -- rpk topic describe cdt.eventos -p` | `partitions: 6`, `replication: 3` | BLOQUEANTE |
| F2.T-5 | DLQ existe con retención 7d | `rpk topic describe cdt.eventos.DLQ -c retention.ms` | `604800000` | BLOQUEANTE |
| F2.T-6 | Apicurio responde | `curl -s -o /dev/null -w '%{http_code}' http://apicurio.asincrono.svc:8080/apis/registry/v3/system/info` | `200` | BLOQUEANTE |
| F2.T-7 | Kong DB-less reachable | `curl -s http://kong-admin.borde.svc:8001/status \| jq .database.reachable` | `false` (modo DB-less) | BLOQUEANTE |
| F2.T-8 | Plugin Prometheus en Kong | `curl -s http://kong-proxy.borde.svc:8000/metrics \| grep -c '^kong_'` | `> 10` métricas | BLOQUEANTE |
| F2.T-9 | Round-trip producer→consumer | `echo "test-$(date)" \| rpk topic produce cdt.eventos` y `rpk topic consume cdt.eventos -n 1` | mismo mensaje retorna en menos de 5 s | BLOQUEANTE |
| F2.T-10 | NetworkPolicy permite servicio↔Postgres del mismo país | pod en `linea-verde` con label `pais=pe` conecta a `postgres-pe.datos.svc:5432` | conexión exitosa | BLOQUEANTE |
| F2.T-11 | NetworkPolicy bloquea cross-país | pod con `pais=pe` intenta conectar a `postgres-mx.datos.svc:5432` | timeout / connection refused | BLOQUEANTE |

**Criterio de promoción a F3:** los 11 tests `BLOQUEANTE` pasan + auditoría aprobada.

## Auditoría requerida al cierre

Invocar `architecture-reviewer`:
1. *"Los 3 clusters Postgres reflejan el patrón XPais del modelo? Los nombres son `AlmacenCDTXPais` instanciados por país?"*
2. *"El tópico `cdt.eventos` corresponde al subsistema `Asincrono` del diagrama y no se han añadido tópicos no documentados?"*
