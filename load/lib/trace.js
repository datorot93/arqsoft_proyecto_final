// load/lib/trace.js
// W3C Trace Context propagation para que cada request de k6 sea localizable
// en Tempo (P1 -> Kong -> cdt-pais -> ACL).
// Spec: https://www.w3.org/TR/trace-context/  formato: 00-{traceId32}-{spanId16}-{flags}.

// SHA-like helper local — pequeño hash determinista de 64 bits a partir de
// (seed, iteration) para el spanId, y 128 bits para el traceId.
// Implementación: dos rondas de splitmix32 concatenadas; suficiente para que
// trace ids sean únicos por iteración y reproducibles por seed.

function splitmix32(z) {
  z = (z + 0x9e3779b9) >>> 0;
  z = Math.imul(z ^ (z >>> 16), 0x85ebca6b) >>> 0;
  z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35) >>> 0;
  return (z ^ (z >>> 16)) >>> 0;
}

function hex32(n) {
  return ("00000000" + (n >>> 0).toString(16)).slice(-8);
}

// traceId 128-bit (32 hex) determinista a partir de (seed, iter).
export function makeTraceId(seed, iter) {
  const a = splitmix32(seed ^ iter);
  const b = splitmix32(a);
  const c = splitmix32(b);
  const d = splitmix32(c);
  return hex32(a) + hex32(b) + hex32(c) + hex32(d);
}

// spanId 64-bit (16 hex) determinista a partir de (seed, iter).
export function makeSpanId(seed, iter) {
  const a = splitmix32((seed * 2654435761) >>> 0 ^ iter);
  const b = splitmix32(a ^ 0xcafebabe);
  return hex32(a) + hex32(b);
}

// Formatea el header W3C `traceparent`. Sampled flag = 01 (recolectar).
export function makeTraceparent(seed, iter) {
  return `00-${makeTraceId(seed, iter)}-${makeSpanId(seed, iter)}-01`;
}
