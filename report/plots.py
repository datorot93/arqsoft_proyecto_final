"""Generación de gráficos SVG embebidos para el reporte F6.

Cada función acepta los datos del snapshot y devuelve un string SVG inline
(no `<img>` ni base64) que se inserta directamente en el HTML.
"""

from __future__ import annotations

import io
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

PLOT_W, PLOT_H = 8.5, 3.5  # pulgadas


def _fig_to_svg(fig) -> str:
    buf = io.StringIO()
    fig.savefig(buf, format="svg", bbox_inches="tight")
    plt.close(fig)
    raw = buf.getvalue()
    # Quitar XML prologue para insertar inline.
    if raw.startswith("<?xml"):
        raw = raw.split("?>", 1)[-1]
    return raw


def _series_from_query(query_block: dict, label_key: str = "") -> list[tuple[str, list, list]]:
    """Devuelve [(label, xs_seconds_relative, ys)] dado el bloque snapshot."""
    out = []
    if not query_block or "result" not in query_block:
        return out
    rs = query_block.get("result", []) or []
    for r in rs:
        metric = r.get("metric", {})
        label = metric.get(label_key, "") if label_key else ""
        if not label and metric:
            label = ", ".join(f"{k}={v}" for k, v in list(metric.items())[:2])
        xs = []
        ys = []
        t0 = None
        for ts, val in r.get("values", []):
            try:
                t = float(ts)
                v = float(val)
            except (TypeError, ValueError):
                continue
            if v != v:  # NaN
                continue
            if t0 is None:
                t0 = t
            xs.append(t - t0)
            ys.append(v)
        if xs:
            out.append((label or "agg", xs, ys))
    return out


def plot_p95_per_minute(snapshot: dict) -> str:
    """Línea P95 por minuto durante el peak. Banda en 800 ms."""
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    qb = snapshot.get("queries", {}).get("p95_peak_per_min", {})
    series = _series_from_query(qb)
    if not series:
        ax.text(0.5, 0.5, "Sin datos del peak", ha="center", va="center", transform=ax.transAxes)
    else:
        for label, xs, ys in series:
            ax.plot(xs, [y * 1000 for y in ys], label=label or "P95", linewidth=1.4)
    ax.axhline(y=800, color="red", linestyle="--", linewidth=1, label="SLA 800 ms")
    ax.set_xlabel("Tiempo dentro del peak (s)")
    ax.set_ylabel("P95 (ms)")
    ax.set_title("AC-2.3 — P95 por minuto durante el peak")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper right", fontsize=8)
    return _fig_to_svg(fig)


def plot_p95_by_pais(snapshot: dict) -> str:
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    qb = snapshot.get("queries", {}).get("p95_peak_by_pais", {})
    series = _series_from_query(qb, label_key="pais")
    if not series:
        ax.text(0.5, 0.5, "Sin datos por país", ha="center", va="center", transform=ax.transAxes)
    else:
        colors = {"pe": "#2C7BB6", "mx": "#D7191C", "co": "#FDAE61"}
        for label, xs, ys in series:
            ax.plot(xs, [y * 1000 for y in ys], label=f"pais={label}", linewidth=1.4, color=colors.get(label, None))
    ax.axhline(y=800, color="red", linestyle="--", linewidth=1, label="SLA 800 ms")
    ax.set_xlabel("Tiempo dentro del peak (s)")
    ax.set_ylabel("P95 (ms)")
    ax.set_title("Estratificación P95 por país (Dirichlet)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper right", fontsize=8)
    return _fig_to_svg(fig)


def plot_load_profile(snapshot: dict) -> str:
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    qb = snapshot.get("queries", {}).get("k6_reqs_rate", {})
    series = _series_from_query(qb)
    if not series:
        ax.text(0.5, 0.5, "Sin métrica k6_http_reqs_total", ha="center", va="center", transform=ax.transAxes)
    else:
        merged_x: dict[float, float] = {}
        for _label, xs, ys in series:
            for x, y in zip(xs, ys):
                merged_x[round(x)] = merged_x.get(round(x), 0.0) + y
        xs = sorted(merged_x.keys())
        ys = [merged_x[x] for x in xs]
        ax.plot(xs, ys, color="#1f77b4", linewidth=1.4)
    ax.set_xlabel("Tiempo (s desde inicio de la ronda)")
    ax.set_ylabel("rate(k6_http_reqs_total) (r/s)")
    ax.set_title("Perfil de carga real observado por k6")
    ax.grid(True, alpha=0.3)
    return _fig_to_svg(fig)


def plot_hpa_events(snapshot: dict) -> str:
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    cur = snapshot.get("queries", {}).get("hpa_current", {})
    des = snapshot.get("queries", {}).get("hpa_desired", {})
    cur_series = _series_from_query(cur, label_key="horizontalpodautoscaler")
    des_series = _series_from_query(des, label_key="horizontalpodautoscaler")
    if not cur_series and not des_series:
        ax.text(0.5, 0.5, "Sin métricas HPA", ha="center", va="center", transform=ax.transAxes)
    else:
        for label, xs, ys in cur_series:
            ax.step(xs, ys, where="post", label=f"current({label})", linewidth=1.2)
        for label, xs, ys in des_series:
            ax.step(xs, ys, where="post", linestyle="--", label=f"desired({label})", linewidth=1.2)
    ax.set_xlabel("Tiempo (s desde inicio de la ronda)")
    ax.set_ylabel("Réplicas")
    ax.set_title("AC-2.5 — HPA current vs desired (cdt-pais-*)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", fontsize=7, ncol=2)
    return _fig_to_svg(fig)


def plot_cb_state(snapshot: dict) -> str:
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    qb = snapshot.get("queries", {}).get("cb_state_open", {})
    series = _series_from_query(qb, label_key="name")
    if not series:
        ax.text(0.5, 0.5, "CB nunca en estado OPEN durante la ronda",
                ha="center", va="center", transform=ax.transAxes)
    else:
        for label, xs, ys in series:
            ax.fill_between(xs, 0, ys, label=f"{label}", alpha=0.5, step="post")
    ax.set_xlabel("Tiempo (s desde inicio)")
    ax.set_ylabel("state=open (1=OPEN)")
    ax.set_title("AC-2.6 — Estado del CircuitBreaker")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper right", fontsize=7)
    return _fig_to_svg(fig)


def plot_aggregate_p95(rounds_data: dict) -> str:
    fig, ax = plt.subplots(figsize=(PLOT_W, PLOT_H))
    rounds = rounds_data.get("rounds", [])
    xs = list(range(1, len(rounds) + 1))
    p95s = []
    p99s = []
    for r in rounds:
        v11 = r.get("verdicts", {}).get("AC-1.1", {}).get("value")
        v12 = r.get("verdicts", {}).get("AC-1.2", {}).get("value")
        try:
            p95s.append(float(v11.replace(" ms", "")) if isinstance(v11, str) else None)
        except Exception:
            p95s.append(None)
        try:
            p99s.append(float(v12.replace(" ms", "")) if isinstance(v12, str) else None)
        except Exception:
            p99s.append(None)
    valid_p95 = [p for p in p95s if p is not None]
    valid_p99 = [p for p in p99s if p is not None]
    if valid_p95:
        ax.plot(xs[: len(valid_p95)], valid_p95, "o-", label="P95 baseline", color="#1f77b4")
    if valid_p99:
        ax.plot(xs[: len(valid_p99)], valid_p99, "s-", label="P99 baseline", color="#ff7f0e")
    ax.axhline(800, color="red", ls="--", lw=1, label="SLA P95 800 ms")
    ax.axhline(1500, color="darkred", ls=":", lw=1, label="SLA P99 1500 ms")
    ax.set_xlabel("Ronda")
    ax.set_ylabel("ms")
    ax.set_title("Distribución agregada P95/P99 baseline por ronda")
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=7)
    return _fig_to_svg(fig)
