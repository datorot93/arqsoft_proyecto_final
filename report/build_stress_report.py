#!/usr/bin/env python3
"""Generador del reporte HTML de la prueba de capacidad (stress_100rps).

Genera un HTML auto-contenido con SVGs inline: perfil de carga, latencia
P50/P95, tasa de error, VUs activos y P95 server-side.

Uso:
    python report/build_stress_report.py --stress-dir runs/results/stress-XXX/
"""

from __future__ import annotations

import argparse
import io
import json
import sys
import time
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from jinja2 import Environment, FileSystemLoader, select_autoescape

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

TEMPLATE_DIR = ROOT / "report"
PLOT_W, PLOT_H = 9.0, 3.5


# ---------------------------------------------------------------------------
# Utilidades de plots
# ---------------------------------------------------------------------------

def _fig_to_svg(fig) -> str:
    buf = io.StringIO()
    fig.savefig(buf, format="svg", bbox_inches="tight")
    plt.close(fig)
    raw = buf.getvalue()
    if raw.startswith("<?xml"):
        raw = raw.split("?>", 1)[-1]
    return raw


def _extract_series(query_block: dict) -> list[tuple[float, float]]:
    """Extrae lista (timestamp, valor) del primer result del query_range."""
    pairs: list[tuple[float, float]] = []
    for series in (query_block.get("result") or []):
        for ts, v in series.get("values", []):
            try:
                val = float(v)
                if val == val:  # not NaN
                    pairs.append((float(ts), val))
            except (ValueError, TypeError):
                pass
        if pairs:
            break
    return pairs


def _normalize_time(pairs: list[tuple[float, float]]) -> tuple[list[float], list[float]]:
    """Devuelve (xs relativas en segundos, ys)."""
    if not pairs:
        return [], []
    t0 = pairs[0][0]
    xs = [(t - t0) for t, _ in pairs]
    ys = [v for _, v in pairs]
    return xs, ys


def plot_req_rate(snapshot: dict) -> str:
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    qb = snapshot.get("queries", {}).get("k6_req_rate", {})
    pairs = _extract_series(qb)
    if not pairs:
        ax.text(0.5, 0.5, "Sin datos k6_http_reqs_total", ha="center", va="center",
                transform=ax.transAxes, fontsize=12)
    else:
        xs, ys = _normalize_time(pairs)
        ax.plot(xs, ys, color="#1f77b4", linewidth=1.6, label="req/s observado")
        ax.axvline(x=180, color="gray", linestyle=":", linewidth=1, alpha=0.7, label="fin ramp-up (3 min)")
        ax.axvline(x=480, color="gray", linestyle="--", linewidth=1, alpha=0.7, label="inicio ramp-down (8 min)")
        ax.axhline(y=100, color="green", linestyle="--", linewidth=1, label="objetivo 100 r/s")
    ax.set_xlabel("Tiempo (s desde inicio del stress test)")
    ax.set_ylabel("r/s")
    ax.set_title("Perfil de carga — stress_100rps (k6 observed rate)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", fontsize=8)
    return _fig_to_svg(fig)


def plot_latency(snapshot: dict) -> str:
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    p95_pairs = _extract_series(snapshot.get("queries", {}).get("k6_p95_latency_ms", {}))
    p50_pairs = _extract_series(snapshot.get("queries", {}).get("k6_p50_latency_ms", {}))
    if not p95_pairs and not p50_pairs:
        ax.text(0.5, 0.5, "Sin datos de latencia k6", ha="center", va="center",
                transform=ax.transAxes, fontsize=12)
    else:
        if p50_pairs:
            xs, ys = _normalize_time(p50_pairs)
            ax.plot(xs, ys, color="#2ca02c", linewidth=1.4, label="P50")
        if p95_pairs:
            xs, ys = _normalize_time(p95_pairs)
            ax.plot(xs, ys, color="#d62728", linewidth=1.6, label="P95")
        ax.axhline(y=800, color="red", linestyle="--", linewidth=1, label="SLA 800 ms")
        ax.axvline(x=180, color="gray", linestyle=":", linewidth=1, alpha=0.5)
        ax.axvline(x=480, color="gray", linestyle="--", linewidth=1, alpha=0.5)
    ax.set_xlabel("Tiempo (s desde inicio del stress test)")
    ax.set_ylabel("Latencia (ms)")
    ax.set_title("Latencia P50/P95 — k6 client-side (ms)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", fontsize=8)
    return _fig_to_svg(fig)


def plot_server_latency(snapshot: dict) -> str:
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    p95_pairs = _extract_series(snapshot.get("queries", {}).get("cdt_p95_server_s", {}))
    p50_pairs = _extract_series(snapshot.get("queries", {}).get("cdt_p50_server_s", {}))
    if not p95_pairs and not p50_pairs:
        ax.text(0.5, 0.5, "Sin datos cdt_open_handler_duration_seconds",
                ha="center", va="center", transform=ax.transAxes, fontsize=12)
    else:
        if p50_pairs:
            xs, ys = _normalize_time(p50_pairs)
            ax.plot(xs, [v * 1000 for v in ys], color="#2ca02c", linewidth=1.4, label="P50 server")
        if p95_pairs:
            xs, ys = _normalize_time(p95_pairs)
            ax.plot(xs, [v * 1000 for v in ys], color="#d62728", linewidth=1.6, label="P95 server")
        ax.axhline(y=800, color="red", linestyle="--", linewidth=1, label="SLA 800 ms")
    ax.set_xlabel("Tiempo (s desde inicio del stress test)")
    ax.set_ylabel("Latencia (ms)")
    ax.set_title("Latencia server-side P50/P95 — cdt_open_handler (Spring Boot/Micrometer)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", fontsize=8)
    return _fig_to_svg(fig)


def plot_vus(snapshot: dict) -> str:
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    pairs = _extract_series(snapshot.get("queries", {}).get("k6_vus", {}))
    if not pairs:
        ax.text(0.5, 0.5, "Sin datos k6_vus", ha="center", va="center",
                transform=ax.transAxes, fontsize=12)
    else:
        xs, ys = _normalize_time(pairs)
        ax.fill_between(xs, 0, ys, alpha=0.35, color="#ff7f0e")
        ax.plot(xs, ys, color="#ff7f0e", linewidth=1.4, label="VUs activos")
        ax.axhline(y=200, color="gray", linestyle=":", linewidth=1, label="preAllocatedVUs=200")
        ax.axhline(y=400, color="red", linestyle=":", linewidth=1, label="maxVUs=400")
    ax.set_xlabel("Tiempo (s desde inicio del stress test)")
    ax.set_ylabel("VUs activos")
    ax.set_title("VUs activos durante el stress test")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", fontsize=8)
    return _fig_to_svg(fig)


def plot_error_rate(snapshot: dict) -> str:
    """Gráfico de totales acumulados de éxito y error."""
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))

    err_pairs = _extract_series(snapshot.get("queries", {}).get("k6_error_total", {}))
    ok_pairs = _extract_series(snapshot.get("queries", {}).get("k6_success_total", {}))

    if not err_pairs and not ok_pairs:
        ax.text(0.5, 0.5, "Sin datos de error/success (k6_cdt_*_total)",
                ha="center", va="center", transform=ax.transAxes, fontsize=12)
    else:
        # Calcular tasa de error porcentual por punto de tiempo
        # Alinear las series por timestamp
        err_dict = {t: v for t, v in err_pairs}
        ok_dict = {t: v for t, v in ok_pairs}
        all_ts = sorted(set(err_dict) | set(ok_dict))
        if all_ts:
            t0 = all_ts[0]
            xs = [t - t0 for t in all_ts]
            # tasa de error puntual = err_count / (err_count + ok_count)
            ys = []
            for t in all_ts:
                e = err_dict.get(t, 0)
                o = ok_dict.get(t, 0)
                total = e + o
                ys.append((e / total * 100) if total > 0 else 0)
            ax.fill_between(xs, 0, ys, alpha=0.4, color="#d62728")
            ax.plot(xs, ys, color="#d62728", linewidth=1.4, label="% error acum.")
            ax.axhline(y=5, color="orange", linestyle="--", linewidth=1, label="umbral 5%")
            ax.axhline(y=20, color="red", linestyle="--", linewidth=1, label="umbral 20%")

    ax.set_xlabel("Tiempo (s desde inicio del stress test)")
    ax.set_ylabel("Tasa de error (%)")
    ax.set_title("Tasa de error acumulada (cdt_error_total / total)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper right", fontsize=8)
    return _fig_to_svg(fig)


# ---------------------------------------------------------------------------
# Builder principal
# ---------------------------------------------------------------------------

def build_stress_html(stress_dir: Path, output: Path | None = None) -> Path:
    summary_path = stress_dir / "stress_summary.json"
    snapshot_path = stress_dir / "stress_snapshot.json"

    summary: dict = json.loads(summary_path.read_text()) if summary_path.exists() else {}
    snapshot: dict = json.loads(snapshot_path.read_text()) if snapshot_path.exists() else {"queries": {}}

    run_id = stress_dir.name
    seed = run_id.split("-s")[-1] if "-s" in run_id else "?"

    def _fmt(val, fmt=".1f", suffix=""):
        if val is None:
            return "N/D"
        try:
            return f"{val:{fmt}}{suffix}"
        except (ValueError, TypeError):
            return "N/D"

    env = Environment(
        loader=FileSystemLoader(str(TEMPLATE_DIR)),
        autoescape=select_autoescape(["html"]),
        trim_blocks=True,
        lstrip_blocks=True,
    )
    tmpl = env.get_template("template_stress.html")

    rendered = tmpl.render(
        run_id=run_id,
        seed=seed,
        duration_s=_fmt(summary.get("duration_s"), ".0f", " s"),
        peak_rps=_fmt(summary.get("peak_rps"), ".1f", " r/s"),
        avg_rps=_fmt(summary.get("avg_rps"), ".1f", " r/s"),
        p95_ms=_fmt(summary.get("p95_ms_sustained"), ".0f", " ms"),
        error_rate=_fmt(summary.get("error_rate_pct"), ".2f", "%"),
        total_requests=_fmt(summary.get("total_requests"), ".0f"),
        error_count=_fmt(summary.get("error_count"), ".0f"),
        plot_req_rate=plot_req_rate(snapshot),
        plot_latency=plot_latency(snapshot),
        plot_server_latency=plot_server_latency(snapshot),
        plot_vus=plot_vus(snapshot),
        plot_error_rate=plot_error_rate(snapshot),
        generated_at=time.strftime("%Y-%m-%d %H:%M:%S UTC"),
    )

    out = output or (stress_dir / "stress_report.html")
    out.write_text(rendered, encoding="utf-8")
    return out


def main() -> int:
    p = argparse.ArgumentParser(description="Generador de reporte HTML de stress test")
    p.add_argument("--stress-dir", required=True, help="Directorio del stress test")
    p.add_argument("--out", help="Path de salida del HTML (default: stress_dir/stress_report.html)")
    args = p.parse_args()

    out = build_stress_html(
        Path(args.stress_dir),
        Path(args.out) if args.out else None,
    )
    print(f"OK · {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
