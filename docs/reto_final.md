## ARTI 4109 - Arquitecturas de Software

## Reto Final: Banco Z — Línea Verde

```
Objetivo: Diseñar la arquitectura de software del sistema propuesto e implementar las decisiones de arquitectura definidas para validar
el cumplimiento de los requerimientos de calidad.
```
```
Contexto: Banco Z es una entidad financiera con más de 20 años de operación en 5 países de Centro y Sudamérica, con fortaleza en
captación de depósitos, créditos y una red de 3. 000 convenios para pago de servicios públicos y privados. Este músculo financiero es su
principal diferenciador frente a competidores digitales. Sin embargo, en los últimos tres años ha perdido mercado frente a neobancos en
segmentos jóvenes y no bancarizados. Su core bancario, estable pero rígido, no fue diseñado para competir a esa velocidad. Ante esto, el
CEO y CIO decidieron crear una unidad digital independiente llamada Línea Verde, con arquitectura y cultura propias, que aproveche el
músculo del banco como habilitador sin quedar atrapada en su inercia.
```
```
Reto: El producto de entrada es el CDT Digital de Alto Rendimiento, que permite abrir un certificado de depósito desde la app sin visitar
una sucursal. El CDT es la puerta de bancarización: el historial generado habilita al cliente para acceder a Crédito Express, un préstamo de
bajo monto con desembolso digital en minutos. La retención se logra con el pago de servicios públicos y privados, servidos a través de la
red del banco principal. Para el cliente es una sola app; por detrás hay dos mundos que deben colaborar sin que uno frene al otro.
```
```
Algunos comportamientos observados:
```
1. En condiciones normales la plataforma recibe 800 solicitudes de apertura de CDT por hora. En días de lanzamiento de tasa se han
    registrado picos de 6. 000 solicitudes en los primeros 20 minutos. Durante estos picos la app ha presentado tiempos de respuesta
    inaceptables y en dos ocasiones dejó de registrar aperturas correctamente.
2. El tiempo desde que un cliente abre su primer CDT hasta ser elegible para Crédito Express es de 4 días hábiles por validaciones
    manuales con el core. La meta del negocio es menos de 10 minutos de forma automatizada.
3. Durante las ventanas de mantenimiento del core ( 1 : 00 am a 4 : 00 am), la Línea Verde pierde capacidad de procesar pagos y consultar
    créditos, afectando clientes en países con husos horarios donde ese horario es de uso activo.
4. Se han presentado casos donde el saldo disponible en la app no refleja el estado real en el core bancario, lo que ha
    generado rechazos inesperados al momento de pagar servicios.
5. Cualquier ajuste en las condiciones del Crédito Express requiere coordinación con tres equipos del banco y ciclos de 3 a 4 semanas. La
    Línea Verde puede entregar en 2 semanas pero opera en ciclos de 6 a 8 por sus dependencias con el core.
6. La suplantación de identidad en la apertura digital fue identificada como riesgo crítico por el área de cumplimiento, dado que el
    proceso no tiene validación presencial.


