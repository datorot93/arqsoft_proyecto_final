// load/lib/mmpp.js
// MMPP-2: Markov-Modulated Poisson Process de 2 estados.
// Documento maestro: docs/experimento_asr.md §4.2.2.
//
// Estados:
//   - calmo:  multiplicador = 1.0, residencia ~ Exp(media = inter-burst-mean).
//   - bursty: multiplicador = 3.0, residencia ~ Exp(media = burst-mean).
//
// Parámetros del documento maestro:
//   media de tiempo en bursty = 20 s
//   media de tiempo entre ráfagas (calmo) = 90 s
//
// Fracción esperada en bursty = 20 / (20 + 90) = 0.1818...
// Tolerancia del spec F5.T-3:  bursty% ∈ [13, 17].
// 18.2% queda LIGERAMENTE arriba del techo del rango.  En la práctica una
// corrida de 20 min tiene varianza alta (pocas transiciones), así que el rango
// muestral [13, 17] se cumple frecuentemente. Si fuese sistemáticamente 18%
// ajustaríamos a calmo-mean=113s (113/(113+20)=15%). Mantenemos los valores
// del documento maestro (autoritativo) — si T-3 falla por overshoot de 1pp se
// documenta en VERIFICACION como matiz, no se modifica el modelo.
//
// API: pre-genera la lista de transiciones [{ tStart, tEnd, state }, ...]
// y expone `multiplierAt(t)` = 1.0 ó 3.0.

import { Rng, sampleExp } from "./sampler.js";

export const STATE_CALMO = "calmo";
export const STATE_BURSTY = "bursty";
export const BURSTY_MULTIPLIER = 3.0;

export function buildMMPPTimeline(seed, duration, opts) {
  const burstyMean = opts && opts.burstyMean ? opts.burstyMean : 20;
  const calmoMean = opts && opts.calmoMean ? opts.calmoMean : 90;
  const initial = opts && opts.initial ? opts.initial : STATE_CALMO;

  const rng = new Rng(seed);
  const segments = [];
  let t = 0;
  let state = initial;
  while (t < duration) {
    const mean = state === STATE_BURSTY ? burstyMean : calmoMean;
    // Exponencial con media `mean` <=> rate = 1/mean.
    const dwell = sampleExp(rng, 1 / mean);
    const tEnd = Math.min(t + dwell, duration);
    segments.push({ tStart: t, tEnd, state, dwell: tEnd - t });
    t = tEnd;
    state = state === STATE_BURSTY ? STATE_CALMO : STATE_BURSTY;
  }
  return segments;
}

// Devuelve { multiplierAt(t), segments, summary } para una run completa.
export function buildMMPP(seed, duration, opts) {
  const segments = buildMMPPTimeline(seed, duration, opts);

  // Búsqueda binaria sobre segments para hot path.
  const tEnds = segments.map((s) => s.tEnd);
  function findSegment(t) {
    if (t < 0 || t >= duration) return null;
    // Binary search: hallar el primer segment cuyo tEnd > t.
    let lo = 0;
    let hi = segments.length - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (tEnds[mid] <= t) lo = mid + 1;
      else hi = mid;
    }
    return segments[lo];
  }

  function multiplierAt(t) {
    const seg = findSegment(t);
    if (!seg) return 1.0;
    return seg.state === STATE_BURSTY ? BURSTY_MULTIPLIER : 1.0;
  }

  function summary() {
    let totalBursty = 0;
    let burstyCount = 0;
    let burstyDurations = [];
    for (const s of segments) {
      if (s.state === STATE_BURSTY) {
        totalBursty += s.dwell;
        burstyCount += 1;
        burstyDurations.push(s.dwell);
      }
    }
    const avgBurstDur =
      burstyDurations.length > 0
        ? burstyDurations.reduce((a, b) => a + b, 0) / burstyDurations.length
        : 0;
    return {
      totalDuration: duration,
      burstyTime: totalBursty,
      burstyFraction: totalBursty / duration,
      burstyCount,
      avgBurstDuration: avgBurstDur,
      segments: segments.length,
    };
  }

  return { multiplierAt, segments, summary, findSegment };
}
