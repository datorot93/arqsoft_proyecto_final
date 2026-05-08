# Fase 8 — Integración end-to-end + README de operación

**Agente principal:** `integration-qa-engineer`
**Documento maestro:** `docs/experimento_asr.md` (todo); todos los specs F1–F7
**Bloquea a:** —
**Modelo sugerido:** sonnet

## Objetivo

**Validar que el proyecto funciona como un todo** ejecutando un ciclo end-to-end desde un cluster limpio, y **producir un `README.md` autoritativo** en la raíz del repositorio que un nuevo integrante pueda seguir para correr el experimento manualmente sin asistencia adicional.

Esta fase NO introduce componentes nuevos — solo orquesta los entregables de F1–F7 y los valida en conjunto.

## Alcance

### 8.1 Smoke test E2E corto (`make e2e-short`)

Versión reducida de la corrida completa, pensada para que CI y desarrolladores la ejecuten en menos de 30 minutos:

| Etapa | Duración (vs producción) | Carga |
|-------|--------------------------|-------|
| Bootstrap (F1) | ~ 3 min | – |
| Plataforma (F2) | ~ 6 min | – |
| Observabilidad (F3) | ~ 4 min | – |
| Servicios (F4) | ~ 5 min | – |
| Carga corta (F5+F6) | 2 min calentamiento + 3 min línea base + 5 min pico | NHPP+MMPP+Dirichlet con λ escalado a 1/4 |
| Análisis y reporte (F6) | ~ 2 min | – |
| **Total** | **~ 27 min** | – |

Volumen objetivo del pico corto: **1 500 CDT en 5 min** (en lugar de 6 000 en 20 min). Mismas distribuciones, escala temporal reducida — es un **smoke test estructural**, no la corrida autoritativa.

### 8.2 Smoke test E2E completo (`make e2e-full`)

Corrida idéntica al experimento autoritativo: N=5 rondas con la duración real (40 min × 5 = ~ 3.5 h con paralelismo).

### 8.3 README.md (raíz del repositorio)

Estructura obligatoria del `README.md`:

```
# Banco Z – Línea Verde · Experimento de validación ASR-1 / ASR-2

## 1. Resumen
   ¿Qué es esto? ¿Qué valida? Versión TL;DR para alguien que abre el repo por primera vez.

## 2. Prerrequisitos
   Versiones EXACTAS y comandos de instalación para Docker, kind, kubectl, Helm, JDK 21, k6, Python, Terraform, gh CLI.

## 3. Estructura del repositorio
   Mapa de carpetas: docs/, diagramas_final/, .claude/, infra/, services/, load/, runs/, report/, scripts/.

## 4. Inicio rápido (3 comandos)
   make up          # bootstrap completo (F1–F4)
   make experiment  # corrida completa (F5+F6)
   make report      # abre el reporte HTML

## 5. Operación detallada por fase
   F1 - Bootstrap
   F2 - Plataforma
   F3 - Observabilidad
   F4 - Servicios
   F5 - Generador de carga
   F6 - Ejecución y análisis
   F7 - CI/CD y OCI
   Cada fase: comando, qué hace, cómo verificar que funciona (referencia a las Pruebas de salida del spec).

## 6. Pruebas manuales por componente
   Smoke test individual de cada componente del subset mínimo viable (§3.1):
   - Kong (curl al admin)
   - cdt-pais (curl POST /v1/cdt)
   - acl (curl al endpoint de prueba)
   - core-stub (curl con header de error rate)
   - Postgres (psql desde pod)
   - Redpanda (rpk produce/consume)
   - Apicurio (curl /apis/registry/v3)
   - Prometheus (query up)
   - Grafana (login y abrir dashboard)
   - Tempo (search por traceId)
   - Loki (logcli query)

## 7. Interpretación del reporte
   Cómo leer el HTML: AC-* PASS/FAIL, percentiles estratificados, mapeo a hipótesis §4.4.

## 8. Solución de problemas (troubleshooting)
   Mínimo 6 escenarios:
   - Docker sin RAM
   - kind no levanta (puertos)
   - HPA no escala
   - Tópico Kafka inexistente
   - CB queda OPEN
   - Reporte sin gráficos

## 9. Migración a OCI
   Resumen del flujo `terraform plan` → `apply` → `helm install` con values-oci.yaml. Referencia a §6.4.11 sobre ATP vs PostgreSQL gestionado.

## 10. Referencias
    - docs/experimento_asr.md (documento maestro)
    - diagramas_final/ (vista estructural)
    - .claude/specs/ (orquestación por fases)
    - .claude/agents/ (agentes responsables)
```

### 8.4 Validador de README

Script `scripts/validate_readme.py` que verifica:
- Las secciones 1–10 existen.
- Cada componente del subset mínimo viable §3.1 tiene comando manual en §6.
- Los comandos `make up`, `make experiment`, `make report` están documentados.
- Las versiones citadas coinciden con `versions.env`.
- Los enlaces internos a `docs/`, `diagramas_final/`, `.claude/specs/`, `.claude/agents/` resuelven (no son 404).
- Hay al menos 6 escenarios en troubleshooting.

## Entradas

- F1–F7 cerradas con sus respectivos gates pasados.
- `docs/experimento_asr.md`, `diagramas_final/componentes.jpeg`, `versions.env`, todas las salidas previas.

## Salidas (artefactos)

| Artefacto | Ruta |
|-----------|------|
| `Makefile` con metas `up`, `down`, `e2e-short`, `e2e-full`, `report`, `nuke`, `validate` | `Makefile` |
| `README.md` autoritativo | `README.md` (raíz) |
| Script de validación del README | `scripts/validate_readme.py` |
| Reporte HTML del E2E corto | `runs/results/e2e-short/report.html` |
| Reporte HTML del E2E completo | `runs/results/e2e-full/report.html` |
| Trazabilidad cumplimiento ASR | `runs/results/e2e-full/asr-compliance.md` |

## Dependencias técnicas

- Todo lo definido en F1–F7. F8 NO añade tooling nuevo.
- `gh` CLI para crear release con artifacts (opcional, F7 ya lo cubre como nightly).

## Pasos de implementación (alto nivel)

1. Implementar `Makefile` con todas las metas, encadenando los scripts/comandos definidos por fase.
2. Implementar variante "corta" del generador de carga (parámetros con `1/4` de escala temporal y volumen).
3. Construir el `README.md` siguiendo la plantilla de §8.3, generando los comandos a partir de los specs F1–F7.
4. Implementar `scripts/validate_readme.py`.
5. Ejecutar `make e2e-short` desde clean clone; iterar hasta que pase.
6. Ejecutar `make e2e-full` con N=5; verificar que los 8 AC-* pasan.
7. Pedir a un compañero que clone limpio y siga el README sin guía verbal — anotar todo lo que tropezó y ajustar.

## Pruebas de salida (gate FINAL del proyecto)

> **Regla del gate:** TODAS las pruebas `BLOQUEANTE` deben pasar para considerar el experimento entregable. Esta es la **última puerta del proyecto**.

| ID | Prueba | Comando concreto | Resultado esperado | Gate |
|----|--------|------------------|--------------------|:----:|
| F8.T-1 | E2E corto desde clean | `make nuke && make e2e-short` | exit `0` en menos de 30 min | BLOQUEANTE |
| F8.T-2 | Los 8 AC-* pasan en E2E corto | `jq 'map(select(.verdict=="PASS")) \| length' runs/results/e2e-short/verdicts.json` | `8` | BLOQUEANTE |
| F8.T-3 | E2E completo (N=5) PASS | `make e2e-full && cat runs/results/e2e-full/aggregate.json \| jq .verdict` | `"EXPERIMENT_PASSED"` | BLOQUEANTE |
| F8.T-4 | `README.md` existe y > 200 líneas | `wc -l README.md` | `> 200` | BLOQUEANTE |
| F8.T-5 | Validador de README pasa | `python scripts/validate_readme.py` | exit `0` | BLOQUEANTE |
| F8.T-6 | Las 10 secciones del README presentes | `grep -c '^## ' README.md` | `≥ 10` | BLOQUEANTE |
| F8.T-7 | Cada componente §3.1 tiene smoke test manual documentado | `python scripts/validate_readme.py --check-component-coverage` | exit `0` | BLOQUEANTE |
| F8.T-8 | ≥ 6 escenarios de troubleshooting | grep en sección §8 del README | `≥ 6` subsecciones | BLOQUEANTE |
| F8.T-9 | Reproducción desde clone limpio | `git clone --depth 1 . /tmp/lv-fresh && cd /tmp/lv-fresh && make e2e-short` | mismo `verdict` que la corrida en el repo principal | BLOQUEANTE |
| F8.T-10 | Versiones del README coinciden con `versions.env` | `python scripts/check_versions.py README.md versions.env` | exit `0` | BLOQUEANTE |
| F8.T-11 | Enlaces internos resuelven | `python scripts/check_links.py README.md` | exit `0` (todos los paths existen) | BLOQUEANTE |
| F8.T-12 | Compañero del equipo logra correr el experimento siguiendo solo el README | dry-run con un colega | feedback positivo, sin necesidad de aclaraciones verbales | BLOQUEANTE |

**Criterio de cierre del proyecto:** los 12 tests `BLOQUEANTE` pasan + auditoría final aprobada.

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|------------|
| `e2e-short` esconde bugs que solo aparecen en la corrida larga | Ejecutar siempre `e2e-full` antes de declarar el experimento aprobado; `e2e-short` es solo gate de PR. |
| README se desactualiza al cambiar versiones | F8.T-10 lo verifica vía `check_versions.py`; F7 incluye este check en CI. |
| Reproducción falla en otros sistemas (macOS, Linux ARM) | Documentar matriz de OS soportados en sección de prerrequisitos; CI corre en Ubuntu/macOS. |
| Compañero del equipo con know-how implícito no detecta gaps | F8.T-12 obligatorio: el reviewer es alguien que NO trabajó en el proyecto. |

## Auditoría requerida al cierre (final del proyecto)

Invocar `architecture-reviewer` con:
1. *"El README cita los 6 componentes del subset mínimo viable (§3.1) con los nombres exactos del modelo del equipo?"*
2. *"El README NO inventa componentes ni renombra los existentes?"*
3. *"El README explicita que `outbox-dispatcher` es detalle de implementación, no componente del diagrama?"*
4. *"El README no recomienda alternativas tecnológicas (Locust, k3d, etc.) sin marcar que están descartadas en §6.4.8 / §6.2.1?"*

Si el reviewer aprueba, el experimento se considera **entregable y reproducible**.
