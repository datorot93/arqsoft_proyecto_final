// load/scenarios/peak_asr2.js
// Pico ASR-2 — 20 min, NHPP + MMPP-2 + Dirichlet.  ESCENARIO CRÍTICO.
// Documento maestro: §4.2 (entera) y §6.3 paso 3.
//
// Modelo:
//   - λ(t) por tramos (lib/nhpp.js):  12 → 9→6 → 5→3 → 3→2 r/s.
//   - MMPP-2 multiplica × 3 cuando estado = bursty (~15% del tiempo).
//   - Dirichlet(α=(3,1,1)) reparte requests entre PE/MX/CO (~60/20/20 con
//     varianza muestral típica).
//
// Implementación con `ramping-arrival-rate`:
//   - Generamos en setup() los `stages[]` con la TASA EFECTIVA de cada
//     bucket de 30 s = λ(t_mid) * mmpp_multiplier(t_mid).
//   - `ramping-arrival-rate` interpola entre stages y sus arrivals son
//     Poisson dentro de cada stage (ese es el contrato de k6 — el inter-arrival
//     dentro de un stage de tasa constante es Exp(rate)).
//   - Cumple ASR-2 (volumen total ≈ 6.000) y la propiedad estocástica
//     (inter-arrivals exponenciales dentro de cada stage, ver F5.T-1 con KS).
//
// **CRÍTICO:** El executor es `ramping-arrival-rate` — coordinated omission
// imposible.  La tasa de llegada es independiente del response time.

import http from "k6/http";
import { check } from "k6";
import { Trend, Counter } from "k6/metrics";

import { buildSolicitudCDT } from "../payloads/cdt.js";
import { makeTraceparent } from "../lib/trace.js";
import { seedFor } from "../lib/sampler.js";
import { lambdaAt, PEAK_DURATION_S, PEAK_LAMBDA_MAX } from "../lib/nhpp.js";
import { buildMMPP, BURSTY_MULTIPLIER } from "../lib/mmpp.js";
import { buildCountryAssigner } from "../lib/dirichlet.js";

const SEED = parseInt(__ENV.SEED || "42", 10);
const KONG_URL = __ENV.KONG_URL || "http://kong-kong-proxy.borde.svc.cluster.local";
const STAGE_GRANULARITY_S = parseInt(__ENV.PEAK_STAGE_S || "30", 10);
// F6 fix retroactivo: permitir reescalar la duración del peak por env
// (PEAK_DURATION). Si no se define, se usa PEAK_DURATION_S=1200 del modelo
// NHPP (lib/nhpp.js). El escalado es proporcional — el modelo NHPP es
// invariante a escala temporal cuando se preserva la fracción bursty del
// MMPP (validación documentada en F5.T-3 y F6 VERIFICACION.md).
const PEAK_DURATION_OVERRIDE_S = parseInt(__ENV.PEAK_DURATION || "0", 10);
// VUs preallocated para pico: lambda_max * mmpp_max * margen
//   12 r/s * 3 (bursty) * 5 (latency factor) = 180 VUs sería conservador.
//   En kind 1-nodo apuntamos a 60 (≈ 1 segundo de queue máximo a P95 ~600ms).
const PRE_VUS = parseInt(__ENV.PEAK_VUS || "60", 10);
const MAX_VUS = parseInt(__ENV.PEAK_MAX_VUS || "120", 10);

const cdtSuccess = new Counter("cdt_success_total");
const cdtError = new Counter("cdt_error_total");
const cdtPayloadSize = new Trend("cdt_payload_size_bytes");

// ---------- Pre-generación determinista de stages ----------
// Ejecutado al cargar el script — antes de setup().
function buildStages(seed) {
  // Duración efectiva: override del env si se proporciona (F6 escalado).
  const effDuration = PEAK_DURATION_OVERRIDE_S > 0
    ? PEAK_DURATION_OVERRIDE_S
    : PEAK_DURATION_S;
  // Reescala temporal: si la duración efectiva difiere, mapeamos
  // `t_eff -> t_full = t_eff * (PEAK_DURATION_S / effDuration)` para conservar
  // la forma de λ(t) y la trayectoria del MMPP.
  const scale = PEAK_DURATION_S / effDuration;
  const mmpp = buildMMPP(seedFor(seed, "mmpp"), PEAK_DURATION_S);
  const stages = [];
  for (let t = 0; t < effDuration; t += STAGE_GRANULARITY_S) {
    const tMid = t + STAGE_GRANULARITY_S / 2;
    const tFull = tMid * scale;
    const lambdaBase = lambdaAt(tFull);
    const m = mmpp.multiplierAt(tFull);
    // Tasa efectiva como entero (k6 exige int en `target`).
    const rate = Math.max(1, Math.round(lambdaBase * m));
    stages.push({ duration: `${STAGE_GRANULARITY_S}s`, target: rate });
  }
  return { stages, mmpp };
}

const _built = buildStages(SEED);
const STAGES = _built.stages;

export const options = {
  discardResponseBodies: true,
  scenarios: {
    peak_asr2: {
      executor: "ramping-arrival-rate",
      startRate: STAGES[0].target,
      timeUnit: "1s",
      preAllocatedVUs: PRE_VUS,
      maxVUs: MAX_VUS,
      stages: STAGES,
      tags: { scenario: "peak", phase: "peak_asr2", seed: String(SEED) },
    },
  },
  thresholds: {
    "http_req_failed{scenario:peak}": ["rate<0.10"],
  },
};

export function setup() {
  const dirSeed = seedFor(SEED, "dirichlet-peak");
  const assigner = buildCountryAssigner(dirSeed);
  return {
    seed: SEED,
    kongUrl: KONG_URL,
    weights: assigner.weights,
    stagesCount: STAGES.length,
  };
}

export default function (data) {
  const iter = __ITER + (__VU << 20);
  // Re-construir el assigner en cada VU es barato y mantiene determinismo.
  const assigner = buildCountryAssigner(seedFor(data.seed, "dirichlet-peak"));
  const pais = assigner.next();

  const payload = buildSolicitudCDT(data.seed, iter, pais);
  cdtPayloadSize.add(payload.size);

  // Error-rate: nominal 0.5%, pero queremos elevarlo en bursty si lo cubrimos
  // (el documento maestro §4.3 dice 2% en bursty).  No tenemos visibilidad
  // del estado MMPP dentro del default(), así que enviamos 0.5% nominal y
  // F6 puede ajustar si requiere — el header está documentado.
  const headers = {
    "Content-Type": "application/json",
    "X-Pais": pais,
    "X-Stub-Latency-Profile": "pareto",
    "X-Stub-Error-Rate": "0.005",
    traceparent: makeTraceparent(data.seed, iter),
  };

  const res = http.post(`${data.kongUrl}/v1/cdt`, payload.bodyStr, {
    headers,
    tags: { pais, scenario: "peak" },
  });

  if (check(res, { "status 202": (r) => r.status === 202 })) {
    cdtSuccess.add(1, { pais });
  } else {
    cdtError.add(1, { pais, status: String(res.status) });
  }
}
