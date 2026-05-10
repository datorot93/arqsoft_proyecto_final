// load/payloads/cdt.js
// Generador de SolicitudCDT JSON con tamaño total ~ Lognormal(μ=ln(2048), σ=0.4).
// Documento maestro: §4.3 (variables aleatorias del cliente).
//
// Estrategia:
//   1) Construir el JSON base con campos requeridos por el contrato F4:
//      { clienteId, monto, plazoDias, tasaAnual }.
//   2) Calcular n_bytes = round( Lognormal(ln(2048), 0.4) ).
//   3) Cap a 8 KB (límite Kong default request size).
//   4) Si n_bytes > base_len: añadir un campo `metadata` con string ASCII
//      de longitud (n_bytes - base_len - overhead-key).
//
// **Decisiones de diseño** (descubiertas runtime, ver VERIFICACION.md):
// - Spring Boot 3.x con Jackson default tiene `FAIL_ON_UNKNOWN_PROPERTIES=false`,
//   así que campos extra son ACEPTADOS por el deserializador del DTO.
// - **Pero**: el `clienteId` está mapeado a `varchar(64)` en Postgres, así
//   que NO podemos usarlo para padding sin romper el INSERT.  Por eso el
//   padding va en un campo extra `metadata` (ignorado por el DTO record).
// - Cap del payload: 8 KB para respetar el default de Kong proxy_buffer_size.

import { Rng, sampleLognormal } from "../lib/sampler.js";

// Cap absoluto del payload: 8 KB (default Kong nginx_http_proxy/_buffer_size).
const MAX_BYTES = 8 * 1024;
const MIN_BYTES = 200; // floor para que siempre haya algún padding o no.

const PADDING_KEY = "metadata";
// Overhead JSON: comma + comilla + key + comilla + dos-puntos + comillas valor.
const PAD_KEY_OVERHEAD = `,"${PADDING_KEY}":""`.length;

const ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

function paddingString(rng, n) {
  if (n <= 0) return "";
  // Usamos PRNG seedeado para que dos corridas con mismo seed produzcan
  // idénticos paddings — necesario para F5.T-6 (hash idéntico).
  let out = "";
  for (let i = 0; i < n; i++) {
    const idx = Math.floor(rng.next() * ALPHABET.length);
    out += ALPHABET[idx];
  }
  return out;
}

// Construye el payload "núcleo" determinista.
function buildCorePayload(rng, iter, pais) {
  // monto ~ uniforme aproximado en {500, 1000, 2000, 5000, 10000}
  const montos = [500, 1000, 2000, 5000, 10000, 25000];
  const monto = montos[Math.floor(rng.next() * montos.length)];
  // plazo en {30, 60, 90, 180, 360}
  const plazos = [30, 60, 90, 180, 360];
  const plazoDias = plazos[Math.floor(rng.next() * plazos.length)];
  // tasa anual ~ U(0.05, 0.12)
  const tasaAnual = +(0.05 + rng.next() * 0.07).toFixed(4);

  return {
    clienteId: `k6-${pais}-${iter}`,
    monto,
    plazoDias,
    tasaAnual,
  };
}

export function buildSolicitudCDT(seed, iter, pais, sigma) {
  // Rng dedicado para este request: independiente del NHPP/MMPP/Dirichlet.
  // (seed ^ iter) garantiza que cada iteración tenga su propio stream.
  const rng = new Rng((seed ^ ((iter + 1) * 2654435761)) >>> 0);

  const core = buildCorePayload(rng, iter, pais);
  // Tamaño base sin padding (sólo los 4 campos requeridos).
  const baseStr = JSON.stringify(core);
  const baseLen = baseStr.length;

  // Lognormal(μ=ln(2048), σ=0.4) — usar Rng interno para no tocar el global.
  const targetSize = Math.round(
    sampleLognormal(rng, Math.log(2048), sigma || 0.4)
  );
  const cappedSize = Math.max(MIN_BYTES, Math.min(MAX_BYTES, targetSize));

  let bodyStr;
  if (cappedSize <= baseLen + PAD_KEY_OVERHEAD) {
    // Payload cabe en el base — emitirlo sin padding.
    bodyStr = baseStr;
  } else {
    // Padding como campo `metadata` ignorado por el DTO (Jackson default).
    const padLen = cappedSize - baseLen - PAD_KEY_OVERHEAD;
    const pad = paddingString(rng, padLen);
    bodyStr = baseStr.slice(0, -1) + `,"${PADDING_KEY}":"${pad}"}`;
  }

  return { bodyStr, size: bodyStr.length, targetSize };
}
