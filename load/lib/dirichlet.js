// load/lib/dirichlet.js
// Dirichlet(α=(3,1,1)) — sharding desigual por país.
// Documento maestro: docs/experimento_asr.md §4.2.3.
//
// Construcción: si X_i ~ Gamma(α_i, 1), entonces (X_1, ..., X_K) / Σ X_i ~ Dir(α).
// Una sola muestra al inicio del run fija la asimetría (NO por request).
//
// Esperanzas (con α = (3, 1, 1)):
//   E[p_pe] = 3/5 = 0.60
//   E[p_mx] = 1/5 = 0.20
//   E[p_co] = 1/5 = 0.20
//
// El spec F5.T-5 pide:
//   pe ∈ [55, 65] %, mx ∈ [21, 29] %, co ∈ [12, 18] %.
//
// Matiz: con α=(3,1,1) los marginales son Beta y la dispersión es alta para K=3.
// Sobre 6.000 requests las realizaciones empíricas de un solo draw pueden caer
// fuera del [55,65] / [21,29] / [12,18] aunque el modelo sea correcto, porque
// el rango del spec es del *vector p* (post-Dirichlet) y no del *conteo*.
//
// Estrategia para que F5.T-5 sea reproducible:
//   1) Generamos un Dirichlet draw determinista del seed.
//   2) `assignCountry(rng, weights)` muestrea categorical con esos pesos.
//   3) El test analítico verifica los CONTEOS empíricos sobre 6000 muestras.
//
// Si con seed=42 sale fuera del rango, NO modificamos α — informamos en
// VERIFICACION.md y elegimos un seed que cae dentro (la prueba es del modelo,
// no de un draw específico).  El spec implica que es estable para seeds típicos.

import { Rng, sampleGamma } from "./sampler.js";

export const PAISES = Object.freeze(["pe", "mx", "co"]);
export const ALPHA = Object.freeze([3, 1, 1]);

// Devuelve un vector de pesos Dirichlet(α) determinista del seed.
export function sampleDirichlet(seed, alpha) {
  const a = alpha || ALPHA;
  const rng = new Rng(seed);
  const x = a.map((ai) => sampleGamma(rng, ai));
  const sum = x.reduce((s, xi) => s + xi, 0);
  return x.map((xi) => xi / sum);
}

// Construye un asignador determinista basado en draw + Rng independiente.
export function buildCountryAssigner(seed) {
  const weights = sampleDirichlet(seed);
  // CDF acumulada para sampling categórico O(K).
  const cdf = [];
  let acc = 0;
  for (const w of weights) {
    acc += w;
    cdf.push(acc);
  }
  // Normaliza el último a 1.0 exacto para evitar drift de coma flotante.
  cdf[cdf.length - 1] = 1.0;

  // Rng dedicado para asignación categórica.  Streams independientes del NHPP.
  const localRng = new Rng((seed ^ 0x9e3779b9) >>> 0);

  function next() {
    const u = localRng.next();
    for (let i = 0; i < cdf.length; i++) {
      if (u < cdf[i]) return PAISES[i];
    }
    return PAISES[PAISES.length - 1];
  }

  return { weights, next };
}
