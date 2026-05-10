// load/scenarios/baseline_asr1.js
// Línea base ASR-1 — 15 min, NHPP a tasa baja (~0.22 r/s ≈ 800 req/h).
// Documento maestro: §6.3 paso 2.
//
// Propósito: medir percentiles bajo CARGA NOMINAL (sin pico, sin MMPP).
// Es el escenario que valida ASR-1 (P95 < 800 ms).
//
// Diferencias clave con peak_asr2:
//   - λ baja y constante (0.22 r/s).
//   - SIN MMPP-2 (sin ráfagas).
//   - SIN Dirichlet por país — distribución uniforme entre los 3 países.
//   - Think-time entre requests del mismo cliente: NO se modela — k6 con
//     `arrival-rate` ya despacha cada request a un VU distinto, así que el
//     think-time del MISMO cliente es irrelevante para el endpoint público.
//     (Documentado: el think-time de §4.3 se aplica al modelado del cliente,
//     pero a nivel del SUT la lectura autoritativa es la tasa de arrivals.)
//
// **NO** se mezcla con peak_asr2.js — son dos artefactos separados, como exige
// el spec (línea base y pico SEPARADOS, no parámetros del mismo escenario).

import http from "k6/http";
import { check } from "k6";
import { Trend, Counter } from "k6/metrics";

import { buildSolicitudCDT } from "../payloads/cdt.js";
import { makeTraceparent } from "../lib/trace.js";
import { seedFor, Rng } from "../lib/sampler.js";

const SEED = parseInt(__ENV.SEED || "42", 10);
const KONG_URL = __ENV.KONG_URL || "http://kong-kong-proxy.borde.svc.cluster.local";
const DURATION_S = parseInt(__ENV.BASELINE_DURATION || "900", 10); // 15 min
// 800 req/h = 800/3600 = 0.222 r/s. k6 requiere int — usamos 1 r/s en window
// 1s pero stages cortos para promedio bajo. Mejor: rate=1, timeUnit="5s" -> 0.2 r/s.
const RATE = parseInt(__ENV.BASELINE_RATE || "1", 10);
const TIME_UNIT = __ENV.BASELINE_TIME_UNIT || "5s"; // 1 req cada 5s = 0.2 r/s.
const PRE_VUS = parseInt(__ENV.BASELINE_VUS || "5", 10);
const MAX_VUS = parseInt(__ENV.BASELINE_MAX_VUS || "10", 10);

const cdtSuccess = new Counter("cdt_success_total");
const cdtError = new Counter("cdt_error_total");
const cdtPayloadSize = new Trend("cdt_payload_size_bytes");

export const options = {
  discardResponseBodies: true,
  scenarios: {
    baseline_asr1: {
      executor: "ramping-arrival-rate",
      startRate: RATE,
      timeUnit: TIME_UNIT,
      preAllocatedVUs: PRE_VUS,
      maxVUs: MAX_VUS,
      stages: [{ duration: `${DURATION_S}s`, target: RATE }],
      tags: { scenario: "baseline", phase: "baseline_asr1", seed: String(SEED) },
    },
  },
  // ASR-1: P95 < 800 ms es el SLA. Establecemos threshold como "documental";
  // F6 hace el veredicto formal con histogramas de Prometheus.
  thresholds: {
    "http_req_duration{scenario:baseline}": ["p(95)<800"],
    "http_req_failed{scenario:baseline}": ["rate<0.05"],
  },
};

export function setup() {
  return { seed: SEED, kongUrl: KONG_URL };
}

export default function (data) {
  const iter = __ITER + (__VU << 20);
  // Línea base: distribución uniforme entre los 3 países (NO Dirichlet).
  const rng = new Rng(seedFor(data.seed, `baseline-pais-${iter}`));
  const idx = Math.floor(rng.next() * 3);
  const pais = ["pe", "mx", "co"][idx];

  const payload = buildSolicitudCDT(data.seed, iter, pais);
  cdtPayloadSize.add(payload.size);

  const headers = {
    "Content-Type": "application/json",
    "X-Pais": pais,
    "X-Stub-Latency-Profile": "pareto",
    "X-Stub-Error-Rate": "0.005",
    traceparent: makeTraceparent(data.seed, iter),
  };

  const res = http.post(`${data.kongUrl}/v1/cdt`, payload.bodyStr, {
    headers,
    tags: { pais, scenario: "baseline" },
  });

  if (check(res, { "status 202": (r) => r.status === 202 })) {
    cdtSuccess.add(1, { pais });
  } else {
    cdtError.add(1, { pais, status: String(res.status) });
  }
}
