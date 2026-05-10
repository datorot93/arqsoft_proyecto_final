"""Percentiles estratificados para el reporte F6.

El documento maestro §5.1 obliga a estratificar P95/P99 por:
    * país (PE/MX/CO) — el más crítico (Dirichlet hot-spotting).
    * pod — diagnostica problemas de scheduling/recursos.
    * estado del CB (CLOSED/OPEN/HALF_OPEN).
    * payload bucket — `cdt_payload_size_bytes` quartiles.

Cada función devuelve un dict con la dimensión y su valor agregado del
percentil sobre la ventana [start, end].
"""

from __future__ import annotations

from typing import Iterable

from .prometheus import PrometheusClient


def _safe_float(v) -> float | None:
    try:
        return float(v[1])
    except (TypeError, IndexError, ValueError):
        return None


def percentile_global(
    prom: PrometheusClient,
    metric: str,
    quantile: float,
    label_filter: str,
    when: float,
    duration_s: int,
) -> float | None:
    """P_q sobre el agregado en `[when - duration_s, when]`.

    Devuelve segundos. Si no hay datos, None.
    """
    q = (
        f"histogram_quantile({quantile}, "
        f"sum by (le) (rate({metric}{{{label_filter}}}[{duration_s}s])))"
    )
    return prom.first_value(q, when=when)


def percentile_by(
    prom: PrometheusClient,
    metric: str,
    quantile: float,
    label_filter: str,
    by_label: str,
    when: float,
    duration_s: int,
) -> dict[str, float]:
    """Devuelve dict {label_value: percentile_s}."""
    q = (
        f"histogram_quantile({quantile}, "
        f"sum by ({by_label}, le) (rate({metric}{{{label_filter}}}[{duration_s}s])))"
    )
    out: dict[str, float] = {}
    for r in prom.query(q, when=when):
        v = _safe_float(r.get("value", []))
        key = r["metric"].get(by_label, "")
        if v is not None and key:
            out[key] = v
    return out


def percentile_per_minute(
    prom: PrometheusClient,
    metric: str,
    quantile: float,
    label_filter: str,
    start: float,
    end: float,
    window_s: int = 60,
) -> list[tuple[float, float | None]]:
    """Serie temporal del percentil con ventanas de `window_s` cada 60 s.

    Devuelve lista [(timestamp, value_s)]. value puede ser None si no hay datos.
    """
    q = (
        f"histogram_quantile({quantile}, "
        f"sum by (le) (rate({metric}{{{label_filter}}}[{window_s}s])))"
    )
    series = prom.query_range(q, start, end, step_s=60)
    if not series:
        return []
    points: list[tuple[float, float | None]] = []
    for ts, val in series[0].get("values", []):
        try:
            v = float(val)
            if v != v:  # NaN
                v = None
        except (TypeError, ValueError):
            v = None
        points.append((float(ts), v))
    return points


def stratified_summary(
    prom: PrometheusClient,
    metric_bucket: str,
    label_filter: str,
    when: float,
    duration_s: int,
    quantiles: Iterable[float] = (0.95, 0.99),
) -> dict:
    """Devuelve un resumen estratificado para los reportes."""
    out = {"global": {}, "by_pais": {}, "by_pod": {}}
    for q in quantiles:
        key = f"p{int(round(q * 100))}"
        out["global"][key] = percentile_global(
            prom, metric_bucket, q, label_filter, when, duration_s
        )
        out["by_pais"][key] = percentile_by(
            prom, metric_bucket, q, label_filter, "pais", when, duration_s
        )
        out["by_pod"][key] = percentile_by(
            prom, metric_bucket, q, label_filter, "pod", when, duration_s
        )
    return out
