// load/scenarios/warmup.js
// Calentamiento — 5 min, tasa constante baja, alinea JIT y connection pools.
// Documento maestro: §6.3 paso 1.
//
// Decisión de executor: `ramping-arrival-rate` (NO constant-vus, NO ramping-vus).
// Razón: incluso para warmup, queremos que las inter-arrivals sean Poisson y NO
// queremos "coordinated omission" si el sistema está aún frío.
//
// `ramping-arrival-rate` con un solo stage en `target = 2 r/s` produce arrivals
// Poisson a tasa media 2/s.  Es la forma correcta del calentamiento.

import http from "k6/http";
import { check } from "k6";
import { Trend, Counter } from "k6/metrics";

import { buildSolicitudCDT } from "../payloads/cdt.js";
import { makeTraceparent } from "../lib/trace.js";
import { buildCountryAssigner } from "../lib/dirichlet.js";
import { seedFor } from "../lib/sampler.js";

// ---------- Config ----------
const SEED = parseInt(__ENV.SEED || "42", 10);
const KONG_URL = __ENV.KONG_URL || "http://kong-kong-proxy.borde.svc.cluster.local";
const DURATION_S = parseInt(__ENV.WARMUP_DURATION || "300", 10);
const RATE = parseInt(__ENV.WARMUP_RATE || "2", 10); // r/s constante
const PRE_VUS = parseInt(__ENV.WARMUP_VUS || "10", 10);
const MAX_VUS = parseInt(__ENV.WARMUP_MAX_VUS || "20", 10);

// Métricas custom (filtrables en Prometheus por scenario).
const cdtSuccess = new Counter("cdt_success_total");
const cdtError = new Counter("cdt_error_total");
const cdtPayloadSize = new Trend("cdt_payload_size_bytes");

// ---------- k6 options ----------
export const options = {
  discardResponseBodies: true,
  scenarios: {
    warmup: {
      executor: "ramping-arrival-rate",
      startRate: RATE,
      timeUnit: "1s",
      preAllocatedVUs: PRE_VUS,
      maxVUs: MAX_VUS,
      stages: [
        // Una sola etapa plana — `ramping-arrival-rate` mantiene la tasa
        // constante pero sigue produciendo arrivals Poisson (independencia).
        { duration: `${DURATION_S}s`, target: RATE },
      ],
      tags: { scenario: "warmup", phase: "warmup", seed: String(SEED) },
    },
  },
  // Un threshold conservador: el sistema en warmup ya debería responder.
  thresholds: {
    "http_req_failed{scenario:warmup}": ["rate<0.10"],
  },
};

// ---------- setup() — una vez al inicio ----------
export function setup() {
  // Dirichlet sample fijo para warmup (reusable cross-iteration).
  const dirSeed = seedFor(SEED, "dirichlet-warmup");
  const assigner = buildCountryAssigner(dirSeed);
  return {
    seed: SEED,
    weights: assigner.weights,
    kongUrl: KONG_URL,
  };
}

// ---------- default() — invocado por cada arrival ----------
export default function (data) {
  const iter = __ITER + (__VU << 20); // identificador único por (vu, iter)
  // Para warmup: distribución Dirichlet fija (no por request).
  const assigner = buildCountryAssigner(seedFor(data.seed, "dirichlet-warmup"));
  const pais = assigner.next();

  const payload = buildSolicitudCDT(data.seed, iter, pais);
  cdtPayloadSize.add(payload.size);

  const headers = {
    "Content-Type": "application/json",
    "X-Pais": pais,
    "X-Stub-Latency-Profile": "pareto",
    "X-Stub-Error-Rate": "0.005", // nominal
    traceparent: makeTraceparent(data.seed, iter),
  };

  const res = http.post(`${data.kongUrl}/v1/cdt`, payload.bodyStr, {
    headers,
    tags: { pais, scenario: "warmup" },
  });

  if (check(res, { "status 202": (r) => r.status === 202 })) {
    cdtSuccess.add(1, { pais });
  } else {
    cdtError.add(1, { pais, status: String(res.status) });
  }
}
