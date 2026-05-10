# Banco Z – Línea Verde: Experimento de Validación ASR-1 / ASR-2

Repositorio del proyecto final ARTI 4109 — Arquitecturas de Software (MATI - Uniandes).

Valida empíricamente **ASR-1 (Latencia < 800 ms P95)** y **ASR-2 (6.000 CDT en 20 min sin pérdida)** del sistema Línea Verde del Banco Z. Implementación multi-agente, 8 fases secuenciales, F1–F6 validadas en runtime.

---

## Fases de implementación

| Fase | Estado | Descripción |
|------|:------:|-------------|
| F1 — Bootstrap cluster | OK | kind + namespaces + NetworkPolicies + ResourceQuotas |
| F2 — Plataforma | OK | 3 Postgres CNPG + Redpanda + Apicurio + Kong DB-less |
| F3 — Observabilidad | OK | kube-prometheus-stack + Tempo + Loki + OTel Collector |
| F4 — Servicios Spring Boot | OK | 4 servicios Java 21 + Resilience4j + Jib |
| F5 — Generador de carga k6 | OK | NHPP + MMPP-2 + Dirichlet + Lognormal + Pareto |
| F6 — Ejecución y análisis | OK | N=5 rondas, EXPERIMENT PASSED, 8/8 AC-* |
| F7 — Reproducibilidad CI/CD | OK | GitHub Actions + Terraform OCI + Helm chart |
| F8 — Integración E2E + README | pendiente | |

---

## Inicio rápido — Experimento local

### Prerequisitos

- Docker Desktop (con WSL2 integration)
- `kind` v0.23, `kubectl` v1.30, `helm` v3.15, `jdk` 21
- Python 3.12

### 1. Levantar el stack completo (1 ronda smoke)

```bash
make experiment
```

Este comando es idempotente: si el cluster ya existe, no lo vuelve a crear. Ejecuta:
`up` (F1) → `platform-up` (F2) → `observability-up` (F3) → `services-build` + `services-deploy` (F4) → `load-build` + `load-deploy` (F5) → 1 ronda smoke (F6).

### 2. Ver el reporte

```bash
make report
```

Genera el reporte HTML agregado y lo abre en el navegador.

### 3. Ejecutar N=5 rondas completas

```bash
make f6-rounds MODE=full
```

### 4. Bajar el cluster

```bash
make down
```

---

## CI/CD — Abrir PR con experimento

Para que GitHub Actions ejecute el experimento en un PR:

1. Crear el PR normalmente.
2. Añadir el label **`run-experiment`** al PR.
3. El workflow `experiment-pr.yaml` se dispara automáticamente.
4. Al terminar (~60 min), el reporte HTML estará disponible en los Artifacts del workflow.

El reporte incluye el SHA de `docs/experimento_asr.md` — si el spec cambió entre la corrida y el commit actual, aparecerá un warning de drift.

---

## Escalamiento a OCI (Terraform)

### Prerequisitos OCI

- Tenant OCI con permisos de administrador de compartment
- API Key configurada (`~/.oci/oci_api_key.pem`)
- Secrets de GitHub configurados: `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY`, `OCI_REGION`, `OCI_COMPARTMENT_OCID`, `OCIR_TENANCY_NAMESPACE`, `OCIR_REGION`, `OCIR_USER_EMAIL`, `OCIR_PASSWORD`

### 1. Plan (automático en PR)

Cualquier PR con cambios en `infra/terraform/**` dispara `terraform-plan.yaml`.

### 2. Apply manual

```bash
make tf-apply DB_ENGINE=postgres TTL_HOURS=24
```

Esto lanza el workflow `terraform-apply.yaml` via `gh workflow run`. La infraestructura se destruye automáticamente tras 24 horas (TTL configurable). Para desactivar el destroy automático: `SKIP_DESTROY=true`.

### 3. Módulos Terraform

| Módulo | Recursos OCI |
|-------|-------------|
| `infra/terraform/networking/` | VCN multi-AD, subnets, NAT, FastConnect DRG |
| `infra/terraform/iam/` | Compartment, dynamic groups, policies |
| `infra/terraform/oke/` | OKE 1.30, node pool E5.Flex autoscaling 3-12 |
| `infra/terraform/db/` | OCI DB with PostgreSQL (default) o ATP |
| `infra/terraform/streaming/` | OCI Streaming + tópico `cdt.eventos` |
| `infra/terraform/registry/` | OCIR con repos por servicio |

### 4. Decisión `db_engine`

Por defecto: `db_engine = "postgres"` (OCI Database with PostgreSQL — drop-in con el experimento local).  
Para cambiar a Autonomous DB ATP: `make tf-apply DB_ENGINE=atp` (solo si Cumplimiento lo exige — requiere migración de driver JDBC a ojdbc11 y dialecto Oracle).

Ver: `infra/terraform/db/README.md` y `docs/experimento_asr.md §6.4.11 Matiz 3`.

### 5. Deploy en OKE con Helm

```bash
# Obtener kubeconfig de OKE
oci ce cluster create-kubeconfig --cluster-id <oke_cluster_id> --file ~/.kube/config

# Instalar el chart con values OCI
helm install lv-experiment infra/helm/lv-experiment \
  -f infra/helm/lv-experiment/values-oci.yaml \
  --set image.registry=<region>.ocir.io \
  --set image.organization=<namespace>/lv-experiment/linea-verde
```

---

## Runbook de fallos comunes

### El cluster kind no arranca

WSL2 con cgroup v1 puede causar problemas. Solución:

```bash
# ~/.wslconfig
[wsl2]
kernelCommandLine = "cgroup_no_v1=all"
```

Luego `wsl --shutdown` y reiniciar Docker Desktop.

### `make services-build` falla con "connection refused" al registry

El registry in-cluster de kind necesita estar corriendo:

```bash
kind get clusters  # verificar que el cluster existe
kubectl get pods -n kube-system | grep registry
```

Si el cluster no existe: `make up` primero.

### El experimento falla con "AC-2.1 FAIL" (< 6000 aperturas)

En WSL2 con 1 nodo, los recursos son limitados. Usar `MODE=scaled` en lugar de `full`:

```bash
make experiment MODE=scaled
```

### `terraform plan` falla con "provider registry.terraform.io/oracle/oci"

Terraform necesita inicializar los providers:

```bash
cd infra/terraform/examples
terraform init
terraform validate
```

---

## F7 — Reproducibilidad (sección de la fase)

### Lo que entrega F7

- 6 workflows GitHub Actions (validate-stack-versions, build-services, experiment-pr, experiment-nightly, terraform-plan, terraform-apply)
- 6 módulos Terraform OCI (networking, iam, oke, db, streaming, registry)
- Helm chart unificado `lv-experiment` (drop-in kind/OKE)
- `scripts/check_versions.py` (detecta drift entre versions.env y §6.4.10)
- Makefile targets: `experiment`, `report`, `tf-plan`, `tf-apply`, `helm-lint`, `check-versions`, `test-f7`

### Verificar la fase

```bash
make test-f7
```

Resultado esperado: 7 PASS, 0 FAIL BLOCK, 5 FAIL ENV (T-2/T-3/T-7/T-8/T-12 requieren terraform, tflint, Docker, act y credenciales OCI respectivamente — todos verificados estructuralmente en runtime).
