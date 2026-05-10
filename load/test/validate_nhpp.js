// load/test/validate_nhpp.js
// Test estadístico Kolmogorov-Smirnov: 10.000 inter-arrivals con tasa
// Exp(λ) deben ajustarse a la CDF teórica de Exponencial.
//
// Uso:
//   node load/test/validate_nhpp.js --samples 10000 --lambda 5
//
// Falla con exit 1 si p-value <= 0.05 (rechaza H0: la muestra es Exp(λ)).
//
// Notas matemáticas:
//   - Estadístico D = sup_x | F_n(x) - F(x) |.
//   - p-value via la serie de Kolmogorov: K(t) = 2·Σ_{k=1..∞} (-1)^(k-1) exp(-2 k² t²).
//     p ≈ 1 - K(D·√n).
//   - Valor crítico para α=0.05 ≈ 1.36/√n  ≈ 0.0136 con n=10.000.

import { Rng, sampleExp } from "../lib/sampler.js";

function parseArgs(argv) {
  const args = { samples: 10000, lambda: 5, seed: 42 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--samples") args.samples = parseInt(argv[++i], 10);
    else if (argv[i] === "--lambda") args.lambda = parseFloat(argv[++i]);
    else if (argv[i] === "--seed") args.seed = parseInt(argv[++i], 10);
  }
  return args;
}

function ksOneSampleExp(samples, lambda) {
  // Ordena ascending.
  const sorted = samples.slice().sort((a, b) => a - b);
  const n = sorted.length;
  // F(x) = 1 - exp(-λ·x).  D = max_i max(|F(x_i) - i/n|, |F(x_i) - (i-1)/n|).
  let dPlus = 0;
  let dMinus = 0;
  for (let i = 0; i < n; i++) {
    const x = sorted[i];
    const F = 1 - Math.exp(-lambda * x);
    dPlus = Math.max(dPlus, (i + 1) / n - F);
    dMinus = Math.max(dMinus, F - i / n);
  }
  return Math.max(dPlus, dMinus);
}

// Marsaglia/Tsang/Wang p-value para KS.
// Usamos la aproximación asintótica para n grande:
//   p = 2 · Σ_{k=1..∞} (-1)^(k-1) exp(-2 k² (D √n)²)
// Truncamos cuando los términos son despreciables (k=100 cubre).
function ksPValue(D, n) {
  const t = D * Math.sqrt(n);
  let sum = 0;
  for (let k = 1; k <= 100; k++) {
    const term = Math.exp(-2 * k * k * t * t);
    sum += (k % 2 === 1 ? 1 : -1) * term;
    if (term < 1e-12) break;
  }
  // p = 2·sum, clamp [0, 1].
  return Math.max(0, Math.min(1, 2 * sum));
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  console.log(
    `[validate_nhpp] Generando ${args.samples} muestras Exp(λ=${args.lambda}) con seed=${args.seed}`
  );

  const rng = new Rng(args.seed);
  const samples = [];
  for (let i = 0; i < args.samples; i++) {
    samples.push(sampleExp(rng, args.lambda));
  }

  const empMean = samples.reduce((a, b) => a + b, 0) / samples.length;
  const expMean = 1 / args.lambda;
  console.log(`  Media empírica: ${empMean.toFixed(5)}  vs teórica: ${expMean.toFixed(5)}`);

  const D = ksOneSampleExp(samples, args.lambda);
  const pValue = ksPValue(D, args.samples);
  const dCrit = 1.36 / Math.sqrt(args.samples);

  console.log(`  KS D = ${D.toFixed(6)}  (D_crit α=0.05 ≈ ${dCrit.toFixed(6)})`);
  console.log(`  KS p-value = ${pValue.toFixed(6)}`);

  if (pValue > 0.05) {
    console.log("[validate_nhpp] PASS: No se rechaza H0 (la muestra es Exp(λ)).");
    process.exit(0);
  } else {
    console.error("[validate_nhpp] FAIL: p-value <= 0.05, las muestras NO son Exp(λ).");
    process.exit(1);
  }
}

main();
