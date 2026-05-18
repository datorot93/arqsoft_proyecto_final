// load/test/integrate_lambda.js
// Integra λ(t) sobre [0, 1200] s y reporta el volumen total esperado.
//
// Uso:  node load/test/integrate_lambda.js
//
// ASR-2 corregido: onset = 100 r/s (6.000 CDT/min). Modelo NHPP re-escalado
// (×100/12 respecto a la versión anterior). Integral analítica = 53.130 CDT.
//
// Cálculo trapezoidal por tramos:
//   P1 [0,120]:    100 * 120         = 12.000
//   P2 [120,420]:  (75+50)/2 * 300   = 18.750
//   P3 [420,900]:  (42+25)/2 * 480   = 16.080
//   P4 [900,1200]: (25+17)/2 * 300   =  6.300
//   Total                            = 53.130
//
// Rango de aceptación: [50.000, 55.000].

import { integrateLambdaAnalytic, integrateLambdaNumeric, PHASES } from "../lib/nhpp.js";

const analytic = integrateLambdaAnalytic();
const numeric = integrateLambdaNumeric(0.1);

console.log("[integrate_lambda] Tramos NHPP:");
for (const [t0, t1, l0, l1, label] of PHASES) {
  const dur = t1 - t0;
  const trap = ((l0 + l1) / 2) * dur;
  console.log(
    `  ${label.padEnd(12)}  [${t0}s, ${t1}s)  λ: ${l0}→${l1} r/s   Σ = ${trap.toFixed(0)} req`
  );
}
console.log(`[integrate_lambda] Total analítico:   ${analytic.toFixed(2)} req`);
console.log(`[integrate_lambda] Total numérico:    ${numeric.toFixed(2)} req`);

const LO = parseInt(process.env.INTEGRAL_LO || "50000", 10);
const HI = parseInt(process.env.INTEGRAL_HI || "55000", 10);

if (analytic >= LO && analytic <= HI) {
  console.log(`[integrate_lambda] PASS: ${analytic.toFixed(2)} ∈ [${LO}, ${HI}]`);
  process.exit(0);
} else {
  console.error(
    `[integrate_lambda] FAIL: ${analytic.toFixed(2)} fuera de [${LO}, ${HI}]`
  );
  process.exit(1);
}
