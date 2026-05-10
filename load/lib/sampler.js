// load/lib/sampler.js
// PRNG y wrappers de inverse-CDF para todas las distribuciones del experimento.
//
// Decisión PRNG (justificada en VERIFICACION.md):
//   - NO usamos `seedrandom` (npm) porque k6 no resuelve npm en runtime y
//     bundlearlo añade fricción sin beneficio.
//   - NO usamos `Math.random()` porque NO es seedable y ROMPE reproducibilidad.
//   - Implementamos `Mulberry32` (32-bit, period 2^32, fast, well-tested) y
//     `splitmix64` para derivar sub-seeds deterministas a partir del seed raíz.
//
// Mismo seed -> misma secuencia byte-a-byte de inter-arrivals, países y payloads.
// Esto se verifica en F5.T-6 (hash SHA-256 de dos corridas idénticas).

// ---------- splitmix64: deriva sub-seeds del seed raíz ----------
// Usado para que `seedFor("nhpp")`, `seedFor("mmpp")` y `seedFor("dirichlet")`
// reciban streams independientes pero deterministas.
//
// Implementación con Math (k6 no soporta BigInt en hot paths consistentemente).
// Tomamos sub-seed = mix32(rootSeed XOR salt32(label)).

function fnv1a32(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

function splitmix32(seed) {
  // Mezcla 32-bit derivada de splitmix64.
  let z = (seed + 0x9e3779b9) >>> 0;
  z = Math.imul(z ^ (z >>> 16), 0x85ebca6b) >>> 0;
  z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35) >>> 0;
  return (z ^ (z >>> 16)) >>> 0;
}

export function seedFor(rootSeed, label) {
  // Sub-seed determinista para un label dado. NO comparte stream con root.
  const salt = fnv1a32(String(label));
  return splitmix32((rootSeed ^ salt) >>> 0);
}

// ---------- Mulberry32: PRNG con seed reproducible ----------
// Period 2^32, very fast, passes BigCrush para uso estadístico.
// Cada `Rng` es independiente: dos Rng con mismo seed producen misma secuencia.

export class Rng {
  constructor(seed) {
    if (typeof seed !== "number" || !Number.isFinite(seed)) {
      throw new Error(`Rng: seed inválido: ${seed}`);
    }
    this._state = (seed >>> 0) || 1;
  }
  // Devuelve uniforme en [0, 1).
  next() {
    this._state = (this._state + 0x6d2b79f5) >>> 0;
    let t = this._state;
    t = Math.imul(t ^ (t >>> 15), t | 1) >>> 0;
    t ^= (t + Math.imul(t ^ (t >>> 7), t | 61)) >>> 0;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }
  // Uniforme abierto (0, 1) — útil para inverse-CDF cuando log(0) o log(1) explotan.
  nextOpen() {
    let u = this.next();
    // Garantiza u ∈ (0, 1): saltamos exactos 0 (con prob 2^-32) y 1 nunca aparece.
    while (u === 0) u = this.next();
    return u;
  }
}

// ---------- Distribuciones por inverse-CDF ----------

// Exponencial(rate): F^-1(u) = -ln(1-u) / rate.  Usamos -ln(u) con u ∈ (0,1).
export function sampleExp(rng, rate) {
  if (rate <= 0) throw new Error(`sampleExp: rate debe ser > 0, vino ${rate}`);
  return -Math.log(rng.nextOpen()) / rate;
}

// Lognormal(mu, sigma): exp(mu + sigma·Z), Z ~ N(0,1) vía Box-Muller.
export function sampleNormal(rng) {
  // Box-Muller estándar; ambos u en (0, 1).
  const u1 = rng.nextOpen();
  const u2 = rng.nextOpen();
  return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
}

export function sampleLognormal(rng, mu, sigma) {
  return Math.exp(mu + sigma * sampleNormal(rng));
}

// Pareto Tipo II / Lomax — referencia, NO se usa en k6.
// Documentación: el core-stub (F4) implementa Pareto (xm=80, alpha=2.5) en Java.
// Esta función queda para tests de validación si se quiere comparar formas.
export function sampleParetoTypeII(rng, xm, alpha) {
  return xm * (Math.pow(1 - rng.nextOpen(), -1 / alpha) - 1);
}

// Gamma(k, theta=1) — Marsaglia-Tsang squeeze cuando k >= 1.
// Para k < 1 usamos boost: Gamma(k) = Gamma(k+1) * U^(1/k).
// Necesario para Dirichlet vía normalización de gammas.
export function sampleGamma(rng, k) {
  if (k <= 0) throw new Error(`sampleGamma: k debe ser > 0, vino ${k}`);
  if (k < 1) {
    const g = sampleGamma(rng, k + 1);
    return g * Math.pow(rng.nextOpen(), 1 / k);
  }
  const d = k - 1 / 3;
  const c = 1 / Math.sqrt(9 * d);
  while (true) {
    let x, v;
    do {
      x = sampleNormal(rng);
      v = 1 + c * x;
    } while (v <= 0);
    v = v * v * v;
    const u = rng.nextOpen();
    if (u < 1 - 0.0331 * x * x * x * x) return d * v;
    if (Math.log(u) < 0.5 * x * x + d * (1 - v + Math.log(v))) return d * v;
  }
}

// Bernoulli(p): true con prob p.  No se usa para errores aquí (los pone el core-stub),
// pero sí para decisiones de muestreo.
export function sampleBernoulli(rng, p) {
  return rng.next() < p;
}
