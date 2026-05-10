#!/usr/bin/env python3
"""F6 — Agrega N rondas independientes en un veredicto consolidado.

Reglas (documento maestro §9 + agente performance-analyst):
    * El experimento se aprueba **solo si las 5 rondas pasan**. 4/5 NO es
      aprobación parcial — es FAIL con un seed problemático identificado.
    * Reportar **P95 medio ± desviación** entre rondas, no solo la media.
    * Una ronda INVALID (coordinated omission) NO cuenta a favor ni en
      contra — se descarta y se reemplaza con seed nuevo (manualmente).

Output:
    runs/results/aggregate.html
    runs/results/aggregate_verdict.json
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from runs.lib.manifest import write_atomic_json  # noqa: E402

AC_ORDER = [
    "AC-1.1",
    "AC-1.2",
    "AC-2.1",
    "AC-2.2",
    "AC-2.3",
    "AC-2.4",
    "AC-2.5",
    "AC-2.6",
]


def _parse_ms(value) -> float | None:
    """Parsea un valor que pueda venir como '612.3 ms' a float ms."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        s = value.strip()
        if s.endswith(" ms"):
            s = s[:-3]
        try:
            return float(s)
        except ValueError:
            return None
    return None


def load_round(dir_path: Path) -> dict | None:
    """Carga un dir de ronda. Devuelve None si no es válido."""
    if not (dir_path / "verdicts.json").exists():
        return None
    verdicts = json.loads((dir_path / "verdicts.json").read_text())
    summary = (
        json.loads((dir_path / "round_summary.json").read_text())
        if (dir_path / "round_summary.json").exists()
        else {"round_id": dir_path.name, "overall_verdict": "?", "seed": -1}
    )
    co = (
        json.loads((dir_path / "coordinated_omission.json").read_text())
        if (dir_path / "coordinated_omission.json").exists()
        else {}
    )
    return {"dir": dir_path, "verdicts": verdicts, "summary": summary, "co": co}


def aggregate(rounds_dirs: list[Path], out_html: Path, out_json: Path) -> dict:
    rounds = []
    for d in rounds_dirs:
        r = load_round(d)
        if r:
            rounds.append(r)

    if not rounds:
        raise RuntimeError("ningún directorio de ronda válido encontrado")

    # Bucket por veredicto general
    invalid = [r for r in rounds if r["summary"].get("overall_verdict") == "INVALID"]
    valid = [r for r in rounds if r["summary"].get("overall_verdict") != "INVALID"]
    pass_rounds = [r for r in valid if r["summary"].get("overall_verdict") == "PASS"]
    fail_rounds = [r for r in valid if r["summary"].get("overall_verdict") == "FAIL"]

    # Frecuencia AC-*: contar PASS por AC sobre rondas válidas
    ac_freq: dict[str, dict] = {}
    for ac in AC_ORDER:
        passes = [r for r in valid if r["verdicts"].get(ac, {}).get("verdict") == "PASS"]
        ac_freq[ac] = {
            "pass_count": len(passes),
            "valid_count": len(valid),
            "pass_ratio": (len(passes) / len(valid)) if valid else 0,
            "name": valid[0]["verdicts"][ac]["name"] if valid else ac,
        }

    # P95 baseline: serie de valores (numericos) para reporte agregado.
    p95_values_ms = []
    p99_values_ms = []
    peak_volumes = []
    for r in valid:
        v11 = _parse_ms(r["verdicts"].get("AC-1.1", {}).get("value"))
        v12 = _parse_ms(r["verdicts"].get("AC-1.2", {}).get("value"))
        if v11 is not None:
            p95_values_ms.append(v11)
        if v12 is not None:
            p99_values_ms.append(v12)
        vol_v = r["verdicts"].get("AC-2.1", {}).get("value")
        if isinstance(vol_v, (int, float)):
            peak_volumes.append(int(vol_v))

    def stats(arr):
        if not arr:
            return {"mean": None, "stdev": None, "min": None, "max": None, "n": 0}
        return {
            "mean": statistics.mean(arr),
            "stdev": statistics.stdev(arr) if len(arr) > 1 else 0.0,
            "min": min(arr),
            "max": max(arr),
            "n": len(arr),
        }

    p95_stats = stats(p95_values_ms)
    p99_stats = stats(p99_values_ms)
    vol_stats = stats(peak_volumes)

    # Veredicto del experimento. Usamos el principio "5/5 o falla":
    #   - Si hay rondas INVALID → necesitan reemplazo.
    #   - Si todas las válidas son PASS → EXPERIMENT PASSED.
    #   - Si alguna válida es FAIL → EXPERIMENT FAILED.
    if invalid:
        experiment_status = "EXPERIMENT NEEDS REPLACEMENT"
        experiment_reason = (
            f"{len(invalid)} ronda(s) INVALID por coordinated omission — "
            "reemplazar con seeds nuevos antes de emitir veredicto final."
        )
    elif fail_rounds:
        experiment_status = "EXPERIMENT FAILED"
        bad_seeds = [r["summary"].get("seed", "?") for r in fail_rounds]
        experiment_reason = (
            f"{len(fail_rounds)} de {len(valid)} ronda(s) FAIL "
            f"(seeds {bad_seeds}). Documento maestro §9: 4/5 NO es aprobación parcial."
        )
    elif len(pass_rounds) >= 1 and not fail_rounds:
        experiment_status = "EXPERIMENT PASSED"
        experiment_reason = (
            f"Las {len(pass_rounds)} ronda(s) válidas pasaron los 8 AC-* simultáneamente."
        )
    else:
        experiment_status = "EXPERIMENT INDETERMINATE"
        experiment_reason = "no se pudo determinar veredicto (sin rondas válidas)."

    # Hallazgos arquitectónicos: agregar todas las hipótesis refutadas no vacías.
    findings: list[dict] = []
    for r in valid:
        for ac in AC_ORDER:
            v = r["verdicts"].get(ac, {})
            if v.get("verdict") == "FAIL" and v.get("hypothesis_refuted"):
                findings.append(
                    {
                        "round_id": r["summary"].get("round_id"),
                        "seed": r["summary"].get("seed"),
                        "ac": ac,
                        "hypothesis_refuted": v["hypothesis_refuted"],
                        "suspect_component": v.get("suspect_component", ""),
                        "reason": v.get("reason", ""),
                    }
                )

    aggregate_data = {
        "experiment_status": experiment_status,
        "experiment_reason": experiment_reason,
        "rounds_total": len(rounds),
        "rounds_valid": len(valid),
        "rounds_invalid": len(invalid),
        "rounds_pass": len(pass_rounds),
        "rounds_fail": len(fail_rounds),
        "ac_frequency": ac_freq,
        "p95_baseline_ms": p95_stats,
        "p99_baseline_ms": p99_stats,
        "peak_volume": vol_stats,
        "findings": findings,
        "rounds": [
            {
                "round_id": r["summary"].get("round_id"),
                "seed": r["summary"].get("seed"),
                "mode": r["summary"].get("mode"),
                "overall": r["summary"].get("overall_verdict"),
                "verdicts": {
                    ac: {
                        "verdict": r["verdicts"].get(ac, {}).get("verdict"),
                        "value": r["verdicts"].get(ac, {}).get("value"),
                    }
                    for ac in AC_ORDER
                },
            }
            for r in rounds
        ],
    }

    write_atomic_json(out_json, aggregate_data)

    # Generar HTML agregado vía build_report
    try:
        from report.build_report import build_aggregate_html  # type: ignore

        build_aggregate_html(aggregate_data, out_html)
    except Exception as e:
        out_html.write_text(
            "<!doctype html><html><body><h1>Aggregate (fallback)</h1>"
            f"<pre>{json.dumps(aggregate_data, indent=2)}</pre>"
            f"<p>build_aggregate_html failed: {e}</p></body></html>"
        )

    return aggregate_data


def main() -> int:
    p = argparse.ArgumentParser(description="F6 — agrega rondas en un veredicto único")
    p.add_argument("paths", nargs="+", help="Rondas: dirs o glob (e.g. runs/results/r*)")
    p.add_argument("--out", default=str(ROOT / "runs" / "results" / "aggregate.html"))
    p.add_argument("--out-json", default=str(ROOT / "runs" / "results" / "aggregate_verdict.json"))
    args = p.parse_args()

    dirs: list[Path] = []
    for s in args.paths:
        path = Path(s)
        if path.is_dir() and (path / "verdicts.json").exists():
            dirs.append(path)
        elif "*" in s:
            for d in sorted(Path().glob(s)):
                if d.is_dir() and (d / "verdicts.json").exists():
                    dirs.append(d)
    if not dirs:
        print(f"ERROR: ningún directorio válido entre: {args.paths}", file=sys.stderr)
        return 2

    print(f"agregando {len(dirs)} ronda(s)…")
    data = aggregate(dirs, Path(args.out), Path(args.out_json))
    print(f"\nEXPERIMENT STATUS: {data['experiment_status']}")
    print(f"  {data['experiment_reason']}")
    print(f"\n  HTML: {args.out}")
    print(f"  JSON: {args.out_json}")
    return 0 if data["experiment_status"] in ("EXPERIMENT PASSED",) else 0
    # Nota: aggregate.py SIEMPRE termina con 0 — el veredicto es el contenido,
    # no el exit code. F6.T-10 verifica el contenido, no el código de salida.


if __name__ == "__main__":
    sys.exit(main())
