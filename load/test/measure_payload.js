// load/test/measure_payload.js
// Genera 1.000 payloads Lognormal(ln(2048), 0.4) y verifica:
//   - Tamaño promedio ≈ 2 KB ± 10%  (1843, 2253) bytes.
//   - Tamaño máximo respeta cap de 8 KB.
//
// Spec F5.T-7.

import { buildSolicitudCDT } from "../payloads/cdt.js";

const SEED = parseInt(process.env.SEED || "42", 10);
const N = parseInt(process.env.N_PAYLOADS || "1000", 10);
const TARGET_MEAN = 2048;
const TOLERANCE_REL = 0.10;
const MAX_BYTES = 8 * 1024;

const sizes = [];
let oversized = 0;
for (let i = 0; i < N; i++) {
  const pais = ["pe", "mx", "co"][i % 3];
  const p = buildSolicitudCDT(SEED, i, pais);
  sizes.push(p.size);
  if (p.size > MAX_BYTES) oversized++;
}

const mean = sizes.reduce((a, b) => a + b, 0) / sizes.length;
const median = sizes.slice().sort((a, b) => a - b)[Math.floor(sizes.length / 2)];
const max = Math.max(...sizes);
const min = Math.min(...sizes);

const lo = TARGET_MEAN * (1 - TOLERANCE_REL);
const hi = TARGET_MEAN * (1 + TOLERANCE_REL);

console.log(`[measure_payload] N=${N} target≈${TARGET_MEAN}B`);
console.log(`  mean=${mean.toFixed(1)}B  median=${median}B  min=${min}B  max=${max}B`);
console.log(`  cap-violations: ${oversized}`);
console.log(`  Rango aceptable: [${lo.toFixed(0)}, ${hi.toFixed(0)}]`);

// La media de Lognormal(μ, σ) = exp(μ + σ²/2).  Con μ=ln(2048), σ=0.4:
// E[size] = 2048 · exp(0.08) ≈ 2218, dentro del 10%.
const meanOk = mean >= lo && mean <= hi;
const noOversize = oversized === 0;

if (meanOk && noOversize) {
  console.log("[measure_payload] PASS");
  process.exit(0);
} else {
  console.error(
    `[measure_payload] FAIL: meanOk=${meanOk} noOversize=${noOversize} (${oversized} > ${MAX_BYTES}B)`
  );
  process.exit(1);
}
