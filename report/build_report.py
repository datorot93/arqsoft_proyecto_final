#!/usr/bin/env python3
"""F6 — Builder del reporte HTML auto-contenido (por ronda y agregado).

Reglas:
    * SVG inline (no `<img src="...">`, no CDN).
    * CSS embebido en el `<style>` del template.
    * No depender de red para abrir el HTML.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, select_autoescape

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from report import plots  # noqa: E402

TEMPLATE_DIR = ROOT / "report"


def _env() -> Environment:
    return Environment(
        loader=FileSystemLoader(str(TEMPLATE_DIR)),
        autoescape=select_autoescape(["html"]),
        trim_blocks=True,
        lstrip_blocks=True,
    )


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


def build_round_html(round_dir: Path, output: Path | None = None) -> Path:
    manifest = json.loads((round_dir / "manifest.json").read_text())
    verdicts = json.loads((round_dir / "verdicts.json").read_text())
    co = json.loads((round_dir / "coordinated_omission.json").read_text())
    summary = (
        json.loads((round_dir / "round_summary.json").read_text())
        if (round_dir / "round_summary.json").exists()
        else {}
    )
    snap_path = round_dir / "prometheus_snapshot.json"
    snapshot = json.loads(snap_path.read_text()) if snap_path.exists() else {"queries": {}}

    overall = summary.get("overall_verdict", "?")
    overall_class = (
        "pass" if overall == "PASS" else "fail" if overall == "FAIL" else "invalid" if overall == "INVALID" else "error"
    )

    env = _env()
    tmpl = env.get_template("template.html")
    rendered = tmpl.render(
        round_id=manifest["round_id"],
        seed=manifest["seed"],
        mode=manifest["config"].get("mode", "?"),
        experiment_spec_sha=manifest["experiment_spec_sha"],
        git_sha=manifest["git_sha"],
        overall=overall,
        overall_reason=summary.get("overall_reason", ""),
        overall_class=overall_class,
        coordinated_omission=co,
        verdicts=verdicts,
        ac_order=AC_ORDER,
        plot_load=plots.plot_load_profile(snapshot),
        plot_p95_min=plots.plot_p95_per_minute(snapshot),
        plot_p95_pais=plots.plot_p95_by_pais(snapshot),
        plot_hpa=plots.plot_hpa_events(snapshot),
        plot_cb=plots.plot_cb_state(snapshot),
        manifest_json=json.dumps(manifest, indent=2),
        generated_at=time.strftime("%Y-%m-%d %H:%M:%S UTC%z"),
    )
    out = output or (round_dir / "report.html")
    out.write_text(rendered)
    return out


def build_aggregate_html(aggregate_data: dict, output: Path) -> Path:
    env = _env()
    tmpl = env.get_template("template_aggregate.html")
    status = aggregate_data["experiment_status"]
    if "PASSED" in status:
        v_class = "pass"
    elif "FAILED" in status:
        v_class = "fail"
    elif "REPLACEMENT" in status:
        v_class = "need"
    else:
        v_class = "other"
    rendered = tmpl.render(
        **aggregate_data,
        verdict_class=v_class,
        ac_order=AC_ORDER,
        plot_p95=plots.plot_aggregate_p95(aggregate_data),
        generated_at=time.strftime("%Y-%m-%d %H:%M:%S UTC%z"),
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered)
    return output


def main() -> int:
    p = argparse.ArgumentParser(description="F6 — generador de reporte HTML")
    p.add_argument("--round-dir", help="Directorio de la ronda (genera report.html dentro)")
    p.add_argument("--aggregate-json", help="Path al aggregate_verdict.json para producir aggregate.html")
    p.add_argument("--out", help="Path de salida del HTML")
    args = p.parse_args()

    if args.round_dir:
        out = build_round_html(Path(args.round_dir), Path(args.out) if args.out else None)
        print(f"OK · {out}")
        return 0
    if args.aggregate_json:
        data = json.loads(Path(args.aggregate_json).read_text())
        out = build_aggregate_html(
            data, Path(args.out) if args.out else (ROOT / "runs" / "results" / "aggregate.html")
        )
        print(f"OK · {out}")
        return 0
    print("ERROR: usar --round-dir o --aggregate-json")
    return 2


if __name__ == "__main__":
    sys.exit(main())
