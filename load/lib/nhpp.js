// load/lib/nhpp.js
// Proceso de Poisson No-Homogéneo (NHPP) por tramos lineales.
// Documento maestro: docs/experimento_asr.md §4.2.1.
//
// ASR-2: el sistema debe soportar 6.000 CDT/minuto = 100 r/s en el onset
// del pico, sostenidos durante una ventana de 20 minutos.
//
// Tabla canónica del pico ASR-2 (20 min = 1200 s):
//
//   t (min)  |  λ(t)  (req/s)             |  Modo
//   ---------+----------------------------+-------------------------
//   0  – 2   |  100                        |  constante (onset abrupto, 6000 CDT/min)
//   2  – 7   |  75 → 50  (lineal)          |  decaimiento
//   7  – 15  |  42 → 25  (lineal)          |  régimen estable
//   15 – 20  |  25 → 17  (lineal)          |  cola
//
// Volumen objetivo:  ∫₀¹²⁰⁰ λ(t) dt  ≈  53.130 CDT  (criterio ASR-2).
//
// Cálculo manual:
//   P1 [0,120]:    100 * 120                                = 12.000
//   P2 [120,420]:  trapezoidal (75+50)/2 * 300              = 18.750
//   P3 [420,900]:  (42+25)/2 * 480                          = 16.080
//   P4 [900,1200]: (25+17)/2 * 300                          =  6.300
//   Total                                                   = 53.130
//
// El test integrate_lambda.js verifica que el total esté en [50.000, 55.000].

export const PHASES = Object.freeze([
  // [tStart_s, tEnd_s, lambdaStart, lambdaEnd, label]
  [0, 120, 100, 100, "P1-onset"],
  [120, 420, 75, 50, "P2-decay"],
  [420, 900, 42, 25, "P3-steady"],
  [900, 1200, 25, 17, "P4-tail"],
]);

export const PEAK_DURATION_S = 1200;
// Lambda máximo del tramo P1 (onset del pico = 100 r/s = 6.000 CDT/min).
// Usado como envelope para thinning del NHPP y cálculo de VUs necesarios.
export const PEAK_LAMBDA_MAX = 100;

// λ(t) — interpolación lineal por tramos.  Devuelve 0 fuera de [0, 1200].
export function lambdaAt(tSeconds) {
  if (tSeconds < 0 || tSeconds >= PEAK_DURATION_S) return 0;
  for (const [t0, t1, l0, l1] of PHASES) {
    if (tSeconds >= t0 && tSeconds < t1) {
      if (l0 === l1) return l0;
      const frac = (tSeconds - t0) / (t1 - t0);
      return l0 + (l1 - l0) * frac;
    }
  }
  return 0;
}

// Integral analítica de λ(t) sobre [0, 1200].
// Cada tramo es trapezoidal:  ∫ = (l0+l1)/2 * (t1-t0).
// Constantes son caso particular con l0 == l1.
export function integrateLambdaAnalytic() {
  let total = 0;
  for (const [t0, t1, l0, l1] of PHASES) {
    total += ((l0 + l1) / 2) * (t1 - t0);
  }
  return total;
}

// Integración numérica por Simpson 1/3 con step pequeño — útil como sanity check.
export function integrateLambdaNumeric(stepSeconds = 0.5) {
  let total = 0;
  for (let t = 0; t < PEAK_DURATION_S; t += stepSeconds) {
    total += lambdaAt(t) * stepSeconds;
  }
  return total;
}

// Inter-arrivals NHPP por *thinning* (algoritmo de Lewis-Shedler).
// Genera tiempos de arribo en [0, durationSeconds] con intensidad lambdaFn(t).
// Esto es lo que ATAQUEN al sistema en peak_asr2.js.
//
// El thinning es la forma matemáticamente correcta de muestrear un NHPP cuando
// λ(t) varía: NO se puede simplemente usar inter-arrivals Exp(λ_promedio).
//
// Argumentos:
//   rng         — instancia Rng (seed determinista).
//   lambdaFn    — función t -> λ(t).
//   lambdaMax   — cota superior global de λ(t) en el intervalo.
//   duration    — horizonte temporal (segundos).
//   multiplier  — multiplicador instantáneo (lo usa MMPP cuando bursty: x3).
//                 Función t -> factor (default 1).
export function sampleArrivalsNHPP(rng, lambdaFn, lambdaMax, duration, multiplierFn) {
  const arrivals = [];
  let t = 0;
  // En MMPP el multiplicador es 3, así que la cota efectiva es lambdaMax * 3.
  const lambdaUpper = lambdaMax * 3.0;
  while (true) {
    // Paso 1: candidato de un Poisson homogéneo a tasa lambdaUpper.
    const u = rng.nextOpen();
    t += -Math.log(u) / lambdaUpper;
    if (t >= duration) break;
    // Paso 2: aceptación con prob λ(t)·m(t) / lambdaUpper.
    const m = multiplierFn ? multiplierFn(t) : 1.0;
    const lambdaT = lambdaFn(t) * m;
    const accept = rng.next();
    if (accept < lambdaT / lambdaUpper) {
      arrivals.push(t);
    }
  }
  return arrivals;
}
