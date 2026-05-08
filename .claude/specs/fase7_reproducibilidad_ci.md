# Fase 7 — Reproducibilidad (CI/CD + IaC OCI)

**Agente principal:** `devops-ci-engineer`
**Documento maestro:** `docs/experimento_asr.md` §6.4.6, §6.4.9, §8 Fase A y D
**Bloquea a:** —
**Modelo sugerido:** sonnet

## Objetivo

Cerrar el ciclo de reproducibilidad: cualquier persona con acceso al repositorio debe poder (1) ejecutar el experimento end-to-end en local con un solo comando y (2) escalar la misma corrida a OCI/OKE con Terraform. El experimento deja de ser "una investigación" y se convierte en una validación que el equipo puede correr antes de cada cambio relevante a Línea Verde.

## Alcance

### CI/CD — GitHub Actions

| Workflow | Disparador | Duración aprox. | Responsabilidad |
|---------|-----------|----------------:|-----------------|
| `validate-stack-versions.yaml` | `push` y `pull_request` | < 1 min | Verifica que `versions.env` no se desincronice con §6.4.10 del documento maestro. |
| `build-services.yaml` | `push` a `main`, tag de release | ~ 8 min | Build con Gradle + Jib, push a OCIR (prod) y a registry de kind (PR). |
| `experiment-pr.yaml` | `pull_request` con label `run-experiment` | ~ 60 min | Levanta kind con F1–F4, ejecuta 1 ronda corta (warmup + baseline) y publica reporte como artifact. |
| `experiment-nightly.yaml` | cron diario | ~ 4 h | Ejecuta N=5 rondas completas y publica reporte agregado. |
| `terraform-plan.yaml` | `pull_request` con cambios en `infra/terraform/` | ~ 3 min | `terraform plan` contra OCI (sin apply). |
| `terraform-apply.yaml` | manual (workflow_dispatch) | variable | `terraform apply` aprovisiona OKE + Autonomous DB / OCI Database with PostgreSQL + OCI Streaming. |

### IaC OCI — Terraform 1.9

| Módulo | Recurso |
|-------|---------|
| `infra/terraform/oke/` | Cluster OKE 1.30 con node pool E5.Flex autoscaling 3-12. |
| `infra/terraform/db/` | OCI Database with PostgreSQL (recomendación opción B del §6.4.11). Variable `db_engine = postgres | atp` para soportar ambos. |
| `infra/terraform/streaming/` | OCI Streaming pool con tópico `cdt.eventos`. |
| `infra/terraform/registry/` | OCI Container Registry (OCIR) con repositorios para cada servicio. |
| `infra/terraform/networking/` | VCN, subnets multi-AD, FastConnect placeholder. |
| `infra/terraform/iam/` | Compartments, dynamic groups, policies para OKE. |

### Empaquetado

- **Jib 3.4** configurado en `build.gradle.kts` para publicar a `${REGISTRY_HOST}/${SERVICE_NAME}:${VERSION}`. Variable `REGISTRY_HOST` cambia entre `kind-registry:5000` y `<region>.ocir.io/<tenancy-namespace>`.
- **Helm chart de la solución** (`infra/helm/lv-experiment/`) que parametriza `replicaCount`, `pais`, `image.tag` y referencia las versiones pinneadas.

### Evidencia y artefactos

- Cada workflow nightly publica como GitHub Release: reporte HTML, manifests de las rondas, valores de seeds.
- Retención de artifacts: 90 días.
- Hash de `experimento_asr.md` se incluye en cada manifest (detecta drift entre el experimento ejecutado y el spec).

## Entradas

- F1–F6 producen los artefactos que CI ejecuta. CI no construye nada que las fases anteriores no puedan construir manualmente.
- §6.4.6 (versiones de cluster), §6.4.9 (CI/CD), §8 Fase D (pipeline reproducible) del documento maestro.

## Salidas (artefactos)

| Artefacto | Ruta sugerida |
|-----------|---------------|
| 6 GitHub Actions workflows | `.github/workflows/*.yaml` |
| Módulos Terraform OCI | `infra/terraform/<modulo>/` |
| Helm chart unificado | `infra/helm/lv-experiment/` |
| `versions.env` con todas las versiones pinneadas | `versions.env` |
| Plantilla de reporte de hallazgos | `report/findings_template.md` |
| `Makefile` con metas `up`, `down`, `experiment`, `report`, `tf-plan`, `tf-apply` | `Makefile` |

## Dependencias técnicas

- **Terraform 1.9** + **OCI Provider 6.x**.
- **GitHub Actions** con runners ubuntu-latest (suficiente para corridas locales en CI; rondas largas pueden requerir self-hosted con más RAM).
- **OCI CLI 3.x** instalado en el runner.
- Secrets de GitHub: `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY`, `OCIR_PASSWORD`.

## Pasos de implementación (alto nivel)

1. Crear `versions.env` con las versiones del §6.4.10. Cualquier cambio a este archivo dispara `validate-stack-versions.yaml`.
2. Configurar Jib en cada subproyecto Gradle para publicar al registry parametrizable.
3. Implementar `build-services.yaml`: matriz por servicio, build paralelo con Jib.
4. Implementar `experiment-pr.yaml`: levanta kind via `kind/create-cluster`, aplica F1–F4, ejecuta una ronda corta (5 + 5 + 5 min) con seed fijo, sube reporte como artifact.
5. Implementar `experiment-nightly.yaml`: 5 rondas completas con seeds derivados de la fecha. Falla si AC-* no pasan.
6. Escribir módulos Terraform OCI con outputs claros (`oke_kubeconfig`, `db_connection_string`, `streaming_bootstrap`).
7. Implementar Helm chart unificado que reciba kubeconfig y haga `helm install` de F1–F4 sobre OKE.
8. Documentar el flujo en `README.md`: cómo correr en local, cómo abrir un PR con label `run-experiment`, cómo escalar a OCI.

## Criterios de éxito

| ID | Criterio | Cómo verificar |
|----|---------|----------------|
| F7.AC-1 | `make experiment` desde clean clone produce reporte HTML válido. | Ejecución desde un Docker fresh termina en menos de 90 min con reporte. |
| F7.AC-2 | PR con label `run-experiment` produce reporte como artifact. | Verificar workflow `experiment-pr` pasa y artifact `report.html` existe. |
| F7.AC-3 | Nightly publica release con N=5 rondas. | Verificar GitHub Releases contiene el último reporte. |
| F7.AC-4 | `terraform plan` para OKE retorna sin errores. | CI workflow `terraform-plan` verde. |
| F7.AC-5 | Hash de `experimento_asr.md` en manifests detecta drift. | Modificar el documento maestro, correr el experimento, observar warning de drift en el reporte. |
| F7.AC-6 | Build de imágenes vía Jib es reproducible. | Mismo SHA git produce mismo digest de imagen (verificable con `crane digest`). |

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|------------|
| Workflow nightly falla intermitentemente | Reintentar 1 vez automáticamente; si falla 2x consecutivos, abrir issue automático. |
| Terraform deja recursos huérfanos en OCI | `terraform destroy` automático tras `terraform-apply` manual con TTL de 24 h por default. |
| Secrets de OCI expuestos en logs | Usar `add-mask` y `secret` de GitHub Actions; CI tiene linter que rechaza `echo $OCI_*`. |
| Drift entre experimento spec y código | F7.AC-5: hash en manifest. Reporte muestra warning si hay desincronización. |

## Pruebas de salida (gate hacia F8)

> **Regla del gate:** TODAS las pruebas `BLOQUEANTE` deben pasar antes de iniciar F8. F8 hace la prueba de integración end-to-end y publica el README — solo tiene sentido si CI/IaC son válidos.

| ID | Prueba | Comando concreto | Resultado esperado | Gate |
|----|--------|------------------|--------------------|:----:|
| F7.T-1 | Workflows válidos | `actionlint .github/workflows/*.yaml` | exit `0` | BLOQUEANTE |
| F7.T-2 | `terraform validate` en cada módulo | `for d in infra/terraform/*/; do terraform -chdir="$d" init -backend=false && terraform -chdir="$d" validate; done` | todos exit `0` | BLOQUEANTE |
| F7.T-3 | `tflint` recursivo limpio | `tflint --recursive --config infra/terraform/.tflint.hcl` | exit `0` | BLOQUEANTE |
| F7.T-4 | `helm lint` chart unificado | `helm lint infra/helm/lv-experiment` | `0 chart(s) failed` | BLOQUEANTE |
| F7.T-5 | `values.schema.json` valida `values-local.yaml` y `values-oci.yaml` | `helm template infra/helm/lv-experiment -f values-local.yaml --validate` y para `values-oci.yaml` | ambos exit `0` | BLOQUEANTE |
| F7.T-6 | `versions.env` coincide con §6.4.10 | `python scripts/check_versions.py docs/experimento_asr.md versions.env` | exit `0` | BLOQUEANTE |
| F7.T-7 | Build Jib reproducible (mismo SHA → mismo digest) | `git checkout <sha> && ./gradlew jibBuildTar` × 2 desde clean state, `crane digest <imagen>` | mismo digest | BLOQUEANTE |
| F7.T-8 | Workflow `experiment-pr` simulado con `act` | `act -W .github/workflows/experiment-pr.yaml -e .github/test-events/pr-with-label.json` | exit `0`, artifact `report.html` presente | BLOQUEANTE |
| F7.T-9 | Hash spec del documento maestro propagado a manifest | comparar `git hash-object docs/experimento_asr.md` con `jq -r .experiment_spec_sha runs/results/<id>/manifest.json` | iguales | BLOQUEANTE |
| F7.T-10 | Secrets nunca expuestos en logs | grep en logs de workflows ya ejecutados (`gh run view --log`) | sin coincidencias de `OCI_*` ni de claves privadas | BLOQUEANTE |
| F7.T-11 | TTL automático para `terraform-apply` | inspección del workflow | hay job `terraform-destroy` programado con TTL 24 h | BLOQUEANTE |
| F7.T-12 | `terraform plan` sin errores contra OCI | `terraform -chdir=infra/terraform/oke plan` con credenciales reales (workflow `terraform-plan`) | exit `0`, `Plan: X to add, 0 to change, 0 to destroy` | BLOQUEANTE |

**Criterio de promoción a F8:** los 12 tests `BLOQUEANTE` pasan + auditoría aprobada.

## Auditoría requerida al cierre

Invocar `architecture-reviewer`:
1. *"Los módulos Terraform reflejan el `despliegue.png` (OKE, Autonomous DB / OCI Database with PostgreSQL, OCI Streaming, FastConnect, OCIR)? Hay servicios que no figuran en el diagrama?"*
2. *"`db_engine` ofrece tanto `postgres` como `atp` — el spec del experimento (§6.4.11) recomienda opción B (PostgreSQL gestionado); la decisión final con el equipo del banco está tomada?"*
