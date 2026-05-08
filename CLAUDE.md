# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Naturaleza del repositorio

Este repositorio **no contiene código ejecutable**: es la entrega del proyecto final del curso **ARTI 4109 - Arquitecturas de Software** (MATI - Uniandes). Toda la entrega es documentación de arquitectura. No hay comandos de build, test ni lint — no intentes inferir un stack de desarrollo.

Idioma de trabajo: **español**. Tanto los entregables como las conversaciones con el usuario se manejan en español.

## Estructura

- `docs/reto_final.md` — Enunciado del caso "Banco Z – Línea Verde". Contiene el contexto de negocio y los **6 comportamientos observados** que motivan los ASRs.
- `docs/ASRs.pdf` — Architecture Significant Requirements priorizados (8 ASRs: Latencia, Escalabilidad, Integración, Disponibilidad-Detección, Modificabilidad, Disponibilidad-Recuperación ×2, Seguridad). Para extraer el texto del PDF usar `pypdf` (instalado con `pip install --user --break-system-packages pypdf`).
- `diagramas/<tipo>/` — Cada diagrama vive en su propia carpeta. Dos formatos según el tipo:
  - **Estructurales y comportamentales** (`componentes`, `clases`, `despliegue`, `secuencia`) — coexisten `<tipo>.mmd` (Mermaid, importable en draw.io vía `Insert > Advanced > Mermaid`) y `<tipo>.puml` (PlantUML, para StarUML con plugin PlantUML). Opcionalmente `<tipo>_explicado.md` con el Mermaid embebido + tabla por subsistema explicando responsabilidades y ASR que justifica cada componente.
  - **Concurrencia** (`concurrencia/`) — formato `.drawio` nativo (XML de draw.io), dividido en 4 archivos de fase (`fase1_apertura_cdt`, `fase2_proteccion_core`, `fase3_consistencia_saldos`, `fase4_seguridad_notificaciones`). No hay `.mmd`/`.puml` para concurrencia: el usuario pidió explícitamente el formato `.drawio` con la misma estética visual que un diagrama de ejemplo que aportó.
- Si existe el `_explicado.md`, **debe quedar sincronizado** con el `.mmd`/`.puml` cuando se modifique el diagrama.

Los cinco tipos de diagramas son: `componentes`, `clases`, `despliegue` (sobre OCI), `secuencia` (apertura de CDT + elegibilidad de Crédito Express), `concurrencia` (4 fases en draw.io).

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
