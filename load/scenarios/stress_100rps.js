// load/scenarios/stress_100rps.js
// Stress test de capacidad — 10 min, ramping-arrival-rate hasta 100 req/s.
//
// Objetivo: superar el techo de 36 r/s del peak ASR-2 (limitado por el modelo
// NHPP λ_max=12 × MMPP×3) y determinar el punto de saturación del sistema.
//
// Perfil de carga:
//   0-3 min:  ramp 10 → 100 r/s  (subida gradual)
//   3-8 min:  sostenido en 100 r/s
//   8-10 min: ramp 100 → 20 r/s  (bajada controlada)
//
// VUs: a 100 r/s con P95 ~600 ms se necesitan ≥60 VUs concurrentes.
// preAllocatedVUs=200, maxVUs=400 da margen para latencias más altas bajo carga.
//
// Usar con:
//   k6 run --env KONG_URL=... --env SEED=42 stress_100rps.js

import http from "k6/http";
import { check } from "k6";
import { Trend, Counter, Rate } from "k6/metrics";

import { buildSolicitudCDT } from "../payloads/cdt.js";
import { makeTraceparent } from "../lib/trace.js";
import { buildCountryAssigner } from "../lib/dirichlet.js";
import { seedFor } from "../lib/sampler.js";

const SEED     = parseInt(__ENV.SEED     || "42",  10);
const KONG_URL = __ENV.KONG_URL || "http://kong-kong-proxy.borde.svc.cluster.local";

const cdtSuccess     = new Counter("cdt_success_total");
const cdtError       = new Counter("cdt_error_total");
const cdtPayloadSize = new Trend("cdt_payload_size_bytes");
const errorRate      = new Rate("cdt_error_rate");

export const options = {
  discardResponseBodies: true,
  scenarios: {
    stress: {
      executor: "ramping-arrival-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 200,
      maxVUs: 400,
      stages: [
        { duration: "3m",  target: 100 },  // ramp-up  10 → 100 r/s
        { duration: "5m",  target: 100 },  // sostenido 100 r/s
        { duration: "2m",  target: 20  },  // ramp-down 100 → 20 r/s
      ],
      tags: { scenario: "stress", phase: "stress_100rps", seed: String(SEED) },
    },
  },
  thresholds: {
    // Umbrales informativos — no bloqueantes (el objetivo es explorar capacidad)
    "http_req_failed{scenario:stress}": ["rate<0.20"],
    "http_req_duration{scenario:stress}": ["p(95)<2000"],
  },
};

export function setup() {
  return {
    seed:    SEED,
    kongUrl: KONG_URL,
  };
}

export default function (data) {
  const iter     = __ITER + (__VU << 20);
  const assigner = buildCountryAssigner(seedFor(data.seed, "dirichlet-stress"));
  const pais     = assigner.next();

  const payload = buildSolicitudCDT(data.seed, iter, pais);
  cdtPayloadSize.add(payload.size);

  const headers = {
    "Content-Type":          "application/json",
    "X-Pais":                pais,
    "X-Stub-Latency-Profile": "pareto",
    "X-Stub-Error-Rate":     "0.005",
    traceparent:             makeTraceparent(data.seed, iter),
  };

  const res = http.post(`${data.kongUrl}/v1/cdt`, payload.bodyStr, {
    headers,
    tags: { pais, scenario: "stress" },
  });

  const ok = check(res, { "status 202": (r) => r.status === 202 });
  if (ok) {
    cdtSuccess.add(1, { pais });
    errorRate.add(0);
  } else {
    cdtError.add(1, { pais, status: String(res.status) });
    errorRate.add(1);
  }
}
