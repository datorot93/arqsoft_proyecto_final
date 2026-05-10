// load/runner/main.js
// Orquesta los 3 escenarios consecutivos en una sola corrida k6.
// Cada escenario corre en su propia ventana temporal (startTime ascendente).
//
// Uso:
//   k6 run load/runner/main.js --env SEED=42 \
//       -o experimental-prometheus-rw=http://prometheus:9090/api/v1/write
//
// k6 ejecuta TODOS los escenarios en el mismo proceso, así que la ventana
// total es warmup (5min) + baseline (15min) + peak (20min) = 40 min.

import http from "k6/http";
import { check } from "k6";
import { Trend, Counter } from "k6/metrics";

import { buildSolicitudCDT } from "../payloads/cdt.js";
import { makeTraceparent } from "../lib/trace.js";
import { seedFor, Rng } from "../lib/sampler.js";
import { lambdaAt, PEAK_DURATION_S } from "../lib/nhpp.js";
import { buildMMPP } from "../lib/mmpp.js";
import { buildCountryAssigner } from "../lib/dirichlet.js";

const SEED = parseInt(__ENV.SEED || "42", 10);
const KONG_URL = __ENV.KONG_URL || "http://kong-kong-proxy.borde.svc.cluster.local";

const STAGE_GRANULARITY_S = 30;

// Pre-genera stages del peak.
function buildPeakStages(seed) {
  const mmpp = buildMMPP(seedFor(seed, "mmpp"), PEAK_DURATION_S);
  const stages = [];
  for (let t = 0; t < PEAK_DURATION_S; t += STAGE_GRANULARITY_S) {
    const tMid = t + STAGE_GRANULARITY_S / 2;
    const rate = Math.max(1, Math.round(lambdaAt(tMid) * mmpp.multiplierAt(tMid)));
    stages.push({ duration: `${STAGE_GRANULARITY_S}s`, target: rate });
  }
  return stages;
}

const PEAK_STAGES = buildPeakStages(SEED);

const cdtSuccess = new Counter("cdt_success_total");
const cdtError = new Counter("cdt_error_total");
const cdtPayloadSize = new Trend("cdt_payload_size_bytes");

export const options = {
  discardResponseBodies: true,
  scenarios: {
    warmup: {
      executor: "ramping-arrival-rate",
      startTime: "0s",
      startRate: 2,
      timeUnit: "1s",
      preAllocatedVUs: 10,
      maxVUs: 20,
      stages: [{ duration: "300s", target: 2 }],
      exec: "warmupHandler",
      tags: { scenario: "warmup", phase: "warmup", seed: String(SEED) },
    },
    baseline_asr1: {
      executor: "ramping-arrival-rate",
      startTime: "300s",
      startRate: 1,
      timeUnit: "5s",
      preAllocatedVUs: 5,
      maxVUs: 10,
      stages: [{ duration: "900s", target: 1 }],
      exec: "baselineHandler",
      tags: { scenario: "baseline", phase: "baseline_asr1", seed: String(SEED) },
    },
    peak_asr2: {
      executor: "ramping-arrival-rate",
      startTime: "1200s",
      startRate: PEAK_STAGES[0].target,
      timeUnit: "1s",
      preAllocatedVUs: 60,
      maxVUs: 120,
      stages: PEAK_STAGES,
      exec: "peakHandler",
      tags: { scenario: "peak", phase: "peak_asr2", seed: String(SEED) },
    },
  },
  thresholds: {
    "http_req_failed{scenario:baseline}": ["rate<0.05"],
    "http_req_failed{scenario:peak}": ["rate<0.10"],
    "http_req_duration{scenario:baseline}": ["p(95)<800"],
  },
};

export function setup() {
  return { seed: SEED, kongUrl: KONG_URL };
}

function postCdt(data, scenarioTag, pais, iter) {
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
    tags: { pais, scenario: scenarioTag },
  });

  if (check(res, { "status 202": (r) => r.status === 202 })) {
    cdtSuccess.add(1, { pais, scenario: scenarioTag });
  } else {
    cdtError.add(1, { pais, status: String(res.status), scenario: scenarioTag });
  }
}

// ---------- Handlers por escenario ----------
export function warmupHandler(data) {
  const iter = __ITER + (__VU << 20);
  const assigner = buildCountryAssigner(seedFor(data.seed, "dirichlet-warmup"));
  const pais = assigner.next();
  postCdt(data, "warmup", pais, iter);
}

export function baselineHandler(data) {
  const iter = __ITER + (__VU << 20);
  // Línea base: uniforme entre 3 países.
  const rng = new Rng(seedFor(data.seed, `baseline-pais-${iter}`));
  const pais = ["pe", "mx", "co"][Math.floor(rng.next() * 3)];
  postCdt(data, "baseline", pais, iter);
}

export function peakHandler(data) {
  const iter = __ITER + (__VU << 20);
  const assigner = buildCountryAssigner(seedFor(data.seed, "dirichlet-peak"));
  const pais = assigner.next();
  postCdt(data, "peak", pais, iter);
}
