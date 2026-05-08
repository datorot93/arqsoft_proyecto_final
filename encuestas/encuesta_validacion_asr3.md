# Encuesta de Validación del ASR-3 — Facilidad de Integración

**Caso:** Banco Z – Línea Verde · Apertura de CDT y elegibilidad para Crédito Express
**Atributo de calidad evaluado:** Facilidad de Integración (`docs/ASRs.pdf` · ASR-3)
**Referencia arquitectónica:** `diagramas_final/componentes.jpeg`, `diagramas_final/clases.jpeg`, `diagramas_final/despliegue.png`
**Versión:** 1.0 · 2026-05-04

---

## 1. Objetivo de la encuesta

El ASR-3 establece que **el sistema de Línea Verde debe poder integrarse con sistemas externos de validación y con el core bancario de Banco Z para establecer la elegibilidad de un cliente para Crédito Express, de forma automática y en menos de 10 minutos**. La unidad de medida del ASR es la *definición de elegibilidad* y su umbral es `< 10 min`.

El objetivo de esta encuesta es **someter el diseño actual** (representado en `diagramas_final/`) a una evaluación experta estructurada que determine si las decisiones arquitectónicas materializadas en los componentes —en particular el subsistema `Integracion` (ACL: `AdaptadorCore`, `TraductorDominio`, `CircuitBreaker`), el `MessageBroker`, el `MotorElegibilidadXPais` y los puntos de integración con sistemas externos (`ValidadorIdentidad`, `ConsultaProveedores`, `Convenios`, `CoreBancoZ`)— **cumplen con la propiedad de Facilidad de Integración** medida en cinco focos técnicos: estándares de comunicación, claridad y desacoplamiento de interfaces, manejo de versiones y compatibilidad hacia atrás, documentación implícita en el diseño, y nivel de acoplamiento entre componentes.

La encuesta se diseñó para que cada pregunta **obligue al evaluador a inspeccionar componentes específicos** del diagrama final, evitando juicios genéricos.

---

## 2. Instrucciones para el experto evaluador

1. Antes de calificar, revise los tres diagramas en `diagramas_final/` (componentes, clases, despliegue) y el enunciado del reto en `docs/reto_final.md`.
2. Cada pregunta cita los componentes de la vista estructural acordada que deben examinarse para responder. Si un componente no aparece o es ambiguo, refleje ese hecho en la calificación.
3. Califique cada pregunta en la **escala de 1 a 5**:

| Valor | Etiqueta | Descripción |
|:-----:|----------|-------------|
| 1 | No cumple en absoluto | El componente o decisión arquitectónica no aparece, o contradice la propiedad evaluada. |
| 2 | Cumple parcialmente bajo | Aparece de forma incipiente; gaps significativos. |
| 3 | Cumple parcialmente | Aparece pero con ambigüedad o decisiones pendientes. |
| 4 | Cumple en alto grado | Decisión presente, justificada y trazable a los diagramas. |
| 5 | Cumple a cabalidad | Decisión explícita, completa y consistente entre componentes, clases y despliegue. |

4. Documente la **justificación** de cada calificación (qué componente o relación específica del diagrama la sustenta).
5. La hoja de cálculo `encuesta_validacion_asr3.xlsx` contiene la misma estructura con fórmulas para el cálculo automático del promedio ponderado y el veredicto.

---

## 3. Cuestionario (10 preguntas)

> **Pesos**: cada pregunta tiene un peso `wᵢ ∈ (0, 1)` que refleja su importancia relativa para el ASR-3. La suma de pesos es **1.00**. Las dimensiones que tocan más directamente el desacople con el `CoreBancoZ` y la cadena de elegibilidad reciben mayor peso, porque son las que más impactan el cumplimiento del SLA de < 10 min y de la operación automática.

| # | ID | Dimensión técnica | Componentes a analizar en `diagramas_final/` | Peso |
|---|-----|-------------------|----------------------------------------------|:----:|
| 1 | Q1 | Estándares de comunicación | `ApiGateway`, `CDTXPais`, `CreditoExpressXPais`, `MotorElegibilidadXPais`, `MessageBroker` | 0.12 |
| 2 | Q2 | Anti-Corruption Layer (ACL) y desacople semántico | `AdaptadorCore`, `TraductorDominio`, `CircuitBreaker`, `CoreBancoZ`, `CDTXPais`, `CreditoExpressXPais`, `Pagos` | 0.15 |
| 3 | Q3 | Asincronía y desacople temporal con el Core | `MessageBroker`, `ChangeDataCapture`, `CoreBancoZ`, `MotorElegibilidadXPais`, `ActualizadorCache` | 0.12 |
| 4 | Q4 | Versionado de eventos y schemas | `MessageBroker`, `MotorElegibilidadXPais`, `Notificaciones`, `DetectorFraude`, `ActualizadorCache` | 0.10 |
| 5 | Q5 | Versionado de APIs públicas y compatibilidad hacia atrás | `ApiGateway`, `AplicacionMovil`, `AplicacionWeb` | 0.08 |
| 6 | Q6 | Integración con proveedores externos heterogéneos | `ValidadorIdentidad`, `ConsultaProveedores`, `Convenios`, `OnboardingXPais`, `MotorElegibilidadXPais`, `Pagos` | 0.10 |
| 7 | Q7 | Automatización de elegibilidad bajo el SLA de 10 minutos | `CDTXPais`, `MessageBroker`, `MotorElegibilidadXPais`, `ConsultaProveedores`, `CacheDistribuido` | 0.12 |
| 8 | Q8 | Cohesión interna y bajo acoplamiento entre subsistemas | `LineaVerde`, `Integracion`, `CoreBancoZ`, `AlmacenCDTXPais`, `AlmacenCreditoXPais`, `AlmacenPagosXPais` | 0.08 |
| 9 | Q9 | Capacidad de evolución multi-país (multi-tenancy) | `CDTXPais`, `CreditoExpressXPais`, `OnboardingXPais`, `AlmacenCDTXPais`, `AlmacenCreditoXPais`, `AlmacenPagosXPais` | 0.06 |
| 10 | Q10 | Resiliencia y aislamiento de fallos en la integración | `CircuitBreaker`, `AdaptadorCore`, `MessageBroker`, `CoreBancoZ`, `CDTXPais`, `CreditoExpressXPais`, `Pagos` | 0.07 |

### 3.1 Tabla de calificación

| ID | Pregunta | Calificación (1–5) | Justificación del experto |
|----|----------|:------------------:|---------------------------|
| **Q1** | ¿En qué medida los componentes `ApiGateway`, `CDTXPais`, `CreditoExpressXPais` y `MotorElegibilidadXPais` exponen contratos en estándares industriales formales (**OpenAPI 3.x** para REST, **AsyncAPI** para los tópicos del `MessageBroker`, **gRPC/Protobuf** para RPC interno) verificables a partir del diagrama de componentes y del diagrama de clases? |   |   |
| **Q2** | ¿Qué tan claro queda el subsistema `Integracion` (`AdaptadorCore` + `TraductorDominio` + `CircuitBreaker`) como una **Anti-Corruption Layer** que evita la fuga del modelo legacy SOAP/CICS de `CoreBancoZ` hacia los servicios de dominio `CDTXPais`, `CreditoExpressXPais` y `Pagos`, manteniendo un modelo de dominio limpio en `LineaVerde`? |   |   |
| **Q3** | ¿El uso del `MessageBroker` (tópicos `cdt.eventos`, `credito.eventos`, `saldo.cambios`, `eventos`) y de `ChangeDataCapture` reduce el acoplamiento síncrono con `CoreBancoZ` y permite que la elegibilidad de Crédito Express fluya **event-driven** sin esperar respuestas síncronas del core? |   |   |
| **Q4** | ¿El diseño contempla un **Schema Registry** y políticas de evolución (compatibilidad **backward/forward**) para los eventos publicados en el `MessageBroker`, de modo que `MotorElegibilidadXPais`, `Notificaciones`, `DetectorFraude` y `ActualizadorCache` puedan evolucionar de manera independiente sin romper a productores existentes? |   |   |
| **Q5** | ¿El `ApiGateway` formaliza una estrategia explícita de **versionado de APIs públicas** (URI versioning, header versioning o contract testing) que permita a `AplicacionMovil` y `AplicacionWeb` coexistir con múltiples versiones simultáneas durante despliegues azules/verdes o canary? |   |   |
| **Q6** | ¿El diseño especifica con suficiente claridad la integración con sistemas externos (`ValidadorIdentidad`, `ConsultaProveedores`, `Convenios`), incluyendo clientes dedicados, contratos definidos, mecanismos de **timeout** y **fallback**, de forma que un cambio en un proveedor externo no propague rotura a los demás? |   |   |
| **Q7** | ¿La cadena `CDTXPais` → `MessageBroker.cdt.eventos` → `MotorElegibilidadXPais` (con consulta a `ConsultaProveedores` y materialización del resultado en `CacheDistribuido`) sustituye plenamente las validaciones manuales que hoy demoran 4 días, manteniéndose dentro del **umbral del ASR-3 de elegibilidad < 10 min** de forma automática? |   |   |
| **Q8** | ¿Las dependencias en el diagrama de componentes muestran que el subsistema `LineaVerde` se acopla a `CoreBancoZ` **exclusivamente a través** del subsistema `Integracion` (sin atajos directos) y a `Datos` por almacén dedicado por contexto (`AlmacenCDTXPais`, `AlmacenCreditoXPais`, `AlmacenPagosXPais`), respetando el principio de **bounded context**? |   |   |
| **Q9** | ¿El patrón `XPais` (sufijo en `CDTXPais`, `CreditoExpressXPais`, `OnboardingXPais`, `AlmacenCDTXPais`, `AlmacenCreditoXPais`, `AlmacenPagosXPais` y el atributo `pais : Pais` en el diagrama de clases) permite **incorporar un nuevo país** o evolucionar las reglas de un país existente, **sin modificar los componentes de los demás países**? |   |   |
| **Q10** | ¿El `CircuitBreaker`, los **pools de hilos/conexiones acotados** en el `AdaptadorCore` y el **buffering** del `MessageBroker` garantizan que una degradación de `CoreBancoZ` **no se traduzca en fallos en cascada** hacia `CDTXPais`, `CreditoExpressXPais`, `Pagos` y los canales (`AplicacionMovil`, `AplicacionWeb`)? |   |   |

---

## 4. Resultado de la Evaluación

### 4.1 Lógica del cálculo

El ASR-3 se considera **CUMPLIDO** únicamente si el **promedio ponderado** de las calificaciones del experto, sobre la escala 1–5, es **estrictamente mayor a 4.0**.

El cálculo es el siguiente:

$$
\overline{S} = \frac{\sum_{i=1}^{10} w_i \cdot s_i}{\sum_{i=1}^{10} w_i} = \sum_{i=1}^{10} w_i \cdot s_i
$$

donde:

- `sᵢ ∈ {1, 2, 3, 4, 5}` es la calificación dada por el experto a la pregunta `i`.
- `wᵢ` es el peso de la pregunta `i`, con `Σ wᵢ = 1.00`.
- `S̄` es el promedio ponderado resultante.

### 4.2 Veredicto

| Condición sobre `S̄` | Veredicto |
|---------------------|-----------|
| `S̄ > 4.0` | ✅ **CUMPLIDO** — El diseño satisface el ASR-3 de Facilidad de Integración. |
| `S̄ ≤ 4.0` | ❌ **NO CUMPLIDO** — Se requiere rediseño. Las preguntas con calificación ≤ 3 indican las dimensiones a reforzar. |

> **Por qué `> 4.0` y no `≥ 4.0`.** Una calificación uniforme de 4 ("cumple en alto grado") en todas las preguntas produce `S̄ = 4.0` exacto. Esto refleja un sistema "aceptable pero con reservas". Para certificar el ASR como **cumplido a nivel auditable** ante el área de Cumplimiento y la oficina del CIO, se exige un margen estricto por encima de ese punto, equivalente a que al menos una dimensión sea calificada en 5 o que el conjunto se distribuya con sesgo positivo hacia 5.

### 4.3 Resumen de cálculo (para diligenciar tras la encuesta)

| Métrica | Valor |
|---------|-------|
| Suma de pesos `Σ wᵢ` | **1.00** (verificación de integridad de la encuesta) |
| Promedio ponderado `S̄` |  |
| Umbral de aprobación | `> 4.0` |
| **Veredicto** |  |

### 4.4 Análisis complementario obligatorio

Independientemente del veredicto global, el reporte final debe incluir:

1. **Mínimo por dimensión**: identificar la pregunta con menor calificación. Si su valor es `≤ 2`, el ASR se considera **NO CUMPLIDO** aunque el promedio ponderado supere 4.0 — porque una integración con una dimensión gravemente débil es un riesgo no compensable.
2. **Mapa hallazgo → componente**: cada calificación `≤ 3` debe traducirse a un ticket de rediseño que apunte al componente específico del diagrama (p. ej. *"Q4 = 2 → No existe Schema Registry; agregar al diagrama de despliegue OCI Streaming + Confluent Schema Registry o equivalente"*).
3. **Trazabilidad al ASR**: cada calificación debe poder enlazarse al elemento concreto del enunciado del ASR-3 (`integración con externos`, `automática`, `< 10 min`).

---

## 5. Anexos

### 5.1 Mapeo pregunta → foco técnico requerido

| Pregunta | Estándares | Desacople de interfaces | Versionado / compatibilidad | Documentación implícita | Acoplamiento |
|----------|:----------:|:----------------------:|:---------------------------:|:-----------------------:|:------------:|
| Q1 | ✅ |  |  | ✅ |  |
| Q2 |  | ✅ |  | ✅ | ✅ |
| Q3 |  | ✅ |  |  | ✅ |
| Q4 | ✅ |  | ✅ |  |  |
| Q5 | ✅ |  | ✅ |  |  |
| Q6 | ✅ | ✅ |  |  | ✅ |
| Q7 |  | ✅ |  |  |  |
| Q8 |  | ✅ |  | ✅ | ✅ |
| Q9 |  | ✅ | ✅ |  | ✅ |
| Q10 |  | ✅ |  |  | ✅ |

Esta matriz garantiza que las **cinco dimensiones técnicas** exigidas por el ASR-3 están representadas: cada columna es cubierta por al menos dos preguntas.

### 5.2 Archivos relacionados

- `encuestas/encuesta_validacion_asr3.xlsx` — Versión Excel diligenciable con fórmulas, validación de datos en la columna de calificación (entero 1–5), formato condicional sobre el veredicto y hoja independiente con el resultado.
- `encuestas/generar_encuesta_asr3.py` — Generador del Excel a partir de la fuente de verdad de las preguntas (permite regenerar la encuesta si se ajustan pesos o redacción).
