# Fase 1 — Bootstrap del cluster local

**Agente principal:** `k8s-platform-engineer`
**Documento maestro:** `docs/experimento_asr.md` §6.2.1, §6.2.3
**Bloquea a:** F2, F3, F4
**Modelo sugerido:** sonnet

## Objetivo

Levantar un cluster Kubernetes local con paridad de API frente a OKE 1.30, listo para que las fases siguientes desplieguen plataforma de datos, observabilidad y servicios sin tener que tocar cluster ni networking.

## Alcance

- Cluster `kind` v0.23 con Kubernetes **v1.30** (versión idéntica a OKE).
- 4 nodos virtuales: 1 control-plane + 3 workers (simulan los 3 *Availability Domains* de OCI).
- Namespaces operativos: `borde`, `linea-verde`, `datos`, `asincrono`, `acl`, `core-stub`, `observabilidad`, `carga`.
- `metrics-server` 0.7 instalado y verificado (HPA depende de él).
- `cert-manager` opcional (necesario solo si fases siguientes requieren TLS interno).
- `NetworkPolicies` que reflejen las dependencias del diagrama de componentes (un servicio de Línea Verde **no puede** saltarse el ACL para llegar al core).
- `ResourceQuotas` por namespace para evitar que un componente acapare el cluster local.

## Entradas

- `docs/experimento_asr.md` §6.2.1 (configuración del cluster) y §6.2.3 (aislamiento).
- `diagramas_final/componentes.jpeg` para validar las dependencias permitidas entre subsistemas.

## Salidas (artefactos)

| Artefacto | Ruta sugerida |
|-----------|---------------|
| Configuración del cluster kind | `infra/kind/cluster.yaml` |
| Manifiestos de namespaces | `infra/k8s/00-namespaces.yaml` |
| `NetworkPolicies` por namespace | `infra/k8s/01-network-policies/` |
| `ResourceQuotas` y `LimitRanges` | `infra/k8s/02-quotas/` |
| Script de bootstrap idempotente | `scripts/bootstrap_cluster.sh` |
| `Makefile` o tasks Justfile con metas `up`, `down`, `nuke` | `Makefile` |

## Dependencias técnicas

- **Docker** 24+ o equivalente runtime.
- **kind** v0.23 (`go install sigs.k8s.io/kind/cmd/kind@v0.23.0`).
- **kubectl** alineado con K8s 1.30.
- **Helm** 3.15.
- **Kustomize** (incluido en `kubectl`).
- Recursos host mínimos: 16 GB RAM, 8 vCPU, 50 GB SSD.

## Pasos de implementación (alto nivel)

1. Definir `cluster.yaml` con 1 control-plane + 3 workers, `kubeadm` patches que fijen K8s 1.30.
2. Habilitar port-forwarding del control-plane y *extra mounts* para los volúmenes de Postgres.
3. Provisionar `metrics-server` con flags `--kubelet-insecure-tls` (necesario en kind).
4. Crear los 8 namespaces con labels `app.kubernetes.io/part-of=linea-verde-experimento`.
5. Aplicar `NetworkPolicies` que prohíban tráfico saliente desde `linea-verde` hacia `core-stub` salvo a través de `acl` (replicar la regla "ACL es único punto al core" del diagrama).
6. Aplicar `ResourceQuotas` con 4 GB RAM y 2 CPU por namespace de aplicación; 8 GB y 4 CPU para `observabilidad` y `datos`.
7. Verificar con `kubectl get nodes` que los 4 nodos están `Ready` y que `metrics-server` responde a `kubectl top nodes`.

## Criterios de éxito

| ID | Criterio | Cómo verificar |
|----|---------|----------------|
| F1.AC-1 | Cluster `Ready` con K8s 1.30. | `kubectl version --short` muestra `Server Version: v1.30.x`. |
| F1.AC-2 | 4 nodos en estado `Ready`. | `kubectl get nodes` lista los 4 con `STATUS=Ready`. |
| F1.AC-3 | `metrics-server` operativo. | `kubectl top nodes` retorna métricas en menos de 30 s. |
| F1.AC-4 | NetworkPolicy bloquea bypass del ACL. | `kubectl exec` desde un pod en `linea-verde` hacia `core-stub` directamente debe **fallar**; vía `acl` debe **éxitosa**. |
| F1.AC-5 | Bootstrap reproducible. | `make nuke && make up` desde cero termina en menos de 5 min y deja el cluster en el mismo estado. |

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|------------|
| Conflicto de puertos (Docker, otro kind) | Script verifica puertos 80/443/30000-32767 antes de crear cluster; aborta con mensaje claro si están ocupados. |
| Falta de RAM en host | `Makefile` valida `free -g` ≥ 14 antes de `up`. |
| Drift de versión K8s | Todas las imágenes y CLIs pinneadas en `versions.env`. CI valida que `kind --version`, `kubectl version`, `helm version` coincidan con las del experimento. |

## Pruebas de salida (gate hacia F2)

> **Regla del gate:** TODAS las pruebas marcadas `BLOQUEANTE` deben pasar antes de iniciar F2. Si una falla, NO se avanza — se itera dentro de F1 hasta cumplir. Las pruebas `INFORMATIVO` se documentan pero no bloquean.

| ID | Prueba | Comando concreto | Resultado esperado | Gate |
|----|--------|------------------|--------------------|:----:|
| F1.T-1 | Cluster Ready | `kubectl wait --for=condition=Ready node --all --timeout=120s` | exit code `0` | BLOQUEANTE |
| F1.T-2 | Versión K8s | `kubectl version -o json \| jq -r .serverVersion.gitVersion` | `v1.30.x` | BLOQUEANTE |
| F1.T-3 | 4 nodos exactos | `kubectl get nodes --no-headers \| wc -l` | `4` | BLOQUEANTE |
| F1.T-4 | metrics-server operativo | `kubectl top nodes` | tabla con CPU%/MEM% para 4 nodos en menos de 30 s | BLOQUEANTE |
| F1.T-5 | 8 namespaces creados | `kubectl get ns -l app.kubernetes.io/part-of=linea-verde-experimento --no-headers \| wc -l` | `8` | BLOQUEANTE |
| F1.T-6 | NetworkPolicy bloquea bypass del ACL | `kubectl run -n linea-verde tmp --rm -i --image=curlimages/curl --restart=Never -- curl -m 5 -o /dev/null -w '%{http_code}' http://core-stub.core-stub.svc:8080/health` | `000` (timeout/conexión rechazada) | BLOQUEANTE |
| F1.T-7 | ResourceQuotas aplicadas | `kubectl get resourcequota -A --no-headers \| wc -l` | `≥ 8` (1 por namespace) | BLOQUEANTE |
| F1.T-8 | Idempotencia bootstrap | `make nuke && make up && make up` | segunda corrida termina sin errores; estado del cluster idéntico | BLOQUEANTE |
| F1.T-9 | Tiempo total de bootstrap | `time make up` desde estado limpio | < 5 min | INFORMATIVO |

**Criterio de promoción a F2:** los 8 tests `BLOQUEANTE` pasan + `architecture-reviewer` aprueba la auditoría (sección siguiente). Si cualquiera falla, F2 no inicia.

## Auditoría requerida al cierre

Invocar `architecture-reviewer` con la pregunta: *"Las NetworkPolicies de F1 reflejan las dependencias permitidas en componentes.jpeg, en particular que LineaVerde solo accede al CoreBancoZ vía Integracion (ACL)?"*. No cerrar la fase si el review marca divergencia.
