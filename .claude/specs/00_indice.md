# Índice de fases — Implementación local del experimento ASR-1 / ASR-2

Este índice gobierna el orden de ejecución de los 7 specs de implementación. Cada fase produce artefactos verificables que la siguiente consume.

**Documento maestro:** [`docs/experimento_asr.md`](../../docs/experimento_asr.md)
**Vista estructural autoritativa:** [`diagramas_final/componentes.jpeg`](../../diagramas_final/componentes.jpeg)
**Reto de origen:** [`docs/reto_final.md`](../../docs/reto_final.md)

## Orden canónico de ejecución

| # | Spec | Agente principal | Bloquea a | Estado |
|---|------|------------------|-----------|--------|
| 1 | [`fase1_bootstrap_cluster.md`](fase1_bootstrap_cluster.md) | `k8s-platform-engineer` | F2, F3, F4 | pendiente |
| 2 | [`fase2_plataforma_datos_mensajeria.md`](fase2_plataforma_datos_mensajeria.md) | `k8s-platform-engineer` | F4, F5 | pendiente |
| 3 | [`fase3_observabilidad.md`](fase3_observabilidad.md) | `observability-engineer` | F4, F6 | pendiente |
| 4 | [`fase4_servicios_aplicacion.md`](fase4_servicios_aplicacion.md) | `spring-boot-developer` | F5, F6 | pendiente |
| 5 | [`fase5_generador_carga.md`](fase5_generador_carga.md) | `load-test-engineer` | F6 | pendiente |
| 6 | [`fase6_ejecucion_analisis.md`](fase6_ejecucion_analisis.md) | `performance-analyst` | F7 | pendiente |
| 7 | [`fase7_reproducibilidad_ci.md`](fase7_reproducibilidad_ci.md) | `devops-ci-engineer` | F8 | pendiente |
| 8 | [`fase8_integracion_e2e_y_readme.md`](fase8_integracion_e2e_y_readme.md) | `integration-qa-engineer` | — (gate final del proyecto) | pendiente |

## Agente transversal (no posee fase)

- [`architecture-reviewer`](../agents/architecture-reviewer.md) — audita cualquier artefacto contra `diagramas_final/componentes.jpeg`. Debe invocarse **al final de cada fase** antes de cerrar el spec.

## Regla de gating obligatoria

> **Cada fase tiene una sección "Pruebas de salida (gate hacia FN+1)" con tests concretos y comandos verificables. La fase siguiente NO inicia hasta que TODAS las pruebas marcadas `BLOQUEANTE` pasen.**

Si una prueba bloqueante falla:
1. NO se avanza a la siguiente fase.
2. Se itera dentro de la fase actual hasta cumplirla.
3. Se documenta en el manifest de la fase qué prueba falló y cómo se resolvió.
4. Pruebas marcadas `INFORMATIVO` se documentan pero no bloquean.

La **Fase 8** es el gate FINAL del proyecto: si sus 12 pruebas bloqueantes pasan + auditoría aprobada + un compañero del equipo logra correr el experimento siguiendo SOLO el `README.md`, el experimento se declara entregable y reproducible.

## Reglas de invocación

1. **No saltar fases.** F4 no puede ejecutar sin F2 (necesita Postgres y Redpanda corriendo). F6 no puede ejecutar sin F5 (necesita el generador de carga listo). F8 no puede ejecutar sin F1–F7 cerradas con sus gates pasados.
2. **No inventar componentes** que no estén en `componentes.jpeg`. Si un flujo parece requerir un actor no modelado, escalar al usuario antes de crear el componente. (Ver CLAUDE.md.)
3. **Mantener paridad de stack** con `docs/experimento_asr.md` §6.4. Versiones pinneadas: Java 21 LTS, Spring Boot 3.3.x, Kong 3.7 OSS, Redpanda 24.2, Postgres 16.4 + CloudNativePG 1.24, k6 v0.53, kube-prometheus-stack 65.x.
4. **Idioma de trabajo: español** en specs, README y comentarios; código y nombres técnicos en inglés.

## Componentes en alcance (de `componentes.jpeg`, sub-set §3.1 del experimento)

- **Borde:** `ApiGateway` (Kong)
- **LineaVerde:** `CDTXPais` (×3 países)
- **Integracion:** `ACL` (`AdaptadorCore` + `CircuitBreaker`)
- **Datos:** `AlmacenCDTXPais` (×3 países, Postgres+CNPG)
- **Asincrono:** `MessageBroker` (Redpanda, tópico `cdt.eventos`)
- **Externos:** `CoreBancoZ` como **stub controlado** (no es el core real)

Excluidos del experimento (justificación en §3.2 del documento maestro): `WAF`, `Autorizador`, `OnboardingXPais`, `ValidadorIdentidad`, `MotorElegibilidadXPais`, `CreditoExpressXPais`, `Pagos`, `Convenios`, `ChangeDataCapture`, `ActualizadorCache`, `CacheDistribuido`, `DetectorFraude`, `LogAuditoria`, `Notificaciones`.
