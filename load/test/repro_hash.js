// load/test/repro_hash.js
// Genera un log de inter-arrivals + países + payload sizes para una corrida
// determinista y emite un SHA-256.  Dos corridas con mismo seed -> hash
// idéntico (F5.T-6).
//
// Uso:
//   node load/test/repro_hash.js --seed 42
//   node load/test/repro_hash.js --seed 42  # debe producir el mismo hash
//
// Si el hash difiere entre runs con mismo seed, hay una fuga de no-determinismo
// (e.g., uso de Math.random, Date.now en algún sampler).

import crypto from "node:crypto";

import { Rng, seedFor, sampleExp } from "../lib/sampler.js";
import { lambdaAt, PEAK_DURATION_S, sampleArrivalsNHPP } from "../lib/nhpp.js";
import { buildMMPP } from "../lib/mmpp.js";
import { buildCountryAssigner } from "../lib/dirichlet.js";
import { buildSolicitudCDT } from "../payloads/cdt.js";

function parseArgs(argv) {
  const args = { seed: 42 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--seed") args.seed = parseInt(argv[++i], 10);
  }
  return args;
}

function generateLog(seed) {
  const lines = [];

  // 1) NHPP arrivals con MMPP multiplier — los que ataquen el SUT en peak.
  const nhppRng = new Rng(seedFor(seed, "nhpp"));
  const mmpp = buildMMPP(seedFor(seed, "mmpp"), PEAK_DURATION_S);
  const arrivals = sampleArrivalsNHPP(
    nhppRng,
    lambdaAt,
    12, // PEAK_LAMBDA_MAX
    PEAK_DURATION_S,
    mmpp.multiplierAt
  );

  // 2) Asignación país.
  const assigner = buildCountryAssigner(seedFor(seed, "dirichlet-peak"));

  // 3) Para cada arrival: emitir línea con timestamp, país, payload-size.
  for (let i = 0; i < arrivals.length; i++) {
    const t = arrivals[i];
    const pais = assigner.next();
    const payload = buildSolicitudCDT(seed, i, pais);
    lines.push(`${t.toFixed(6)}\t${pais}\t${payload.size}`);
  }

  return lines.join("\n");
}

const args = parseArgs(process.argv.slice(2));
const log = generateLog(args.seed);
const hash = crypto.createHash("sha256").update(log).digest("hex");

const lineCount = log.split("\n").length;
console.error(`[repro_hash] seed=${args.seed} lines=${lineCount}`);
console.error(`[repro_hash] sha256=${hash}`);

// stdout solo el hash — para que `diff` funcione directo.
console.log(hash);
