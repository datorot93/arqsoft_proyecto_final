"""Validador de coordinated omission.

Regla del documento maestro §5.1 y agente performance-analyst:
    Si `arrival_rate` real (lo que el SUT ve llegar) está por debajo del
    `target_rate` configurado en k6 en más del 2 %, la ronda se marca
    INVALID (no FAIL). Esto significa que el cliente no logró sostener la
    tasa, ya sea porque saturó VUs o porque el SUT bloqueó las llegadas
    (que sería el escenario de coordinated omission clásico).

Implementación:
    * `target_rate` se extrae de la configuración de cada escenario (lo
      computa el orquestador antes de lanzar el TestRun).
    * `actual_rate` se mide con `rate(k6_http_reqs_total[$window])` o, si
      no se dispone de la métrica con label `scenario`, con
      `rate(cdt_open_handler_duration_seconds_count[$window])`.
    * El umbral (`min_ratio`) es 0.98 (drift < 2 %).
    * Para warmup la tolerancia es más laxa (0.95) — los primeros segundos
      tienen JIT y connection pool init.
"""

from __future__ import annotations

from dataclasses import dataclass

from .prometheus import PrometheusClient


@dataclass
class CoordinatedOmissionVerdict:
    phase: str
    target_rate_rps: float
    actual_rate_rps: float
    ratio: float
    threshold: float
    valid: bool
    reason: str

    def to_dict(self) -> dict:
        return self.__dict__.copy()


def measure_actual_rate(
    prom: PrometheusClient,
    phase: str,
    start: float,
    end: float,
) -> float:
    """Tasa real de ingreso al SUT durante la fase `phase`.

    Estrategia:
      1. Preferir `k6_http_reqs_total{phase=phase}` (lo que el cliente envió).
      2. Caer a `cdt_open_handler_duration_seconds_count{phase=phase}` (lo
         que el servicio recibió).
      3. Caer a `cdt_open_handler_duration_seconds_count` agregado.
    """
    duration = max(1.0, end - start)
    queries = [
        f'sum(increase(k6_http_reqs_total{{phase="{phase}"}}[{int(duration)}s]))',
        f'sum(increase(cdt_open_handler_duration_seconds_count{{phase="{phase}"}}[{int(duration)}s]))',
        f"sum(increase(cdt_open_handler_duration_seconds_count[{int(duration)}s]))",
    ]
    for q in queries:
        v = prom.first_value(q, when=end)
        if v is not None and v > 0:
            return v / duration
    return 0.0


def evaluate(
    prom: PrometheusClient,
    phase: str,
    target_rate_rps: float,
    start: float,
    end: float,
    min_ratio: float = 0.98,
) -> CoordinatedOmissionVerdict:
    """Calcula si la fase está libre de coordinated omission."""
    actual = measure_actual_rate(prom, phase, start, end)
    ratio = (actual / target_rate_rps) if target_rate_rps > 0 else 0.0
    valid = ratio >= min_ratio
    if target_rate_rps <= 0:
        reason = "target_rate=0 (configuración inválida)"
        valid = False
    elif actual <= 0:
        reason = "no se observó tráfico real (k6_http_reqs_total=0)"
        valid = False
    elif valid:
        reason = (
            f"arrival_rate ({actual:.3f} r/s) ≥ {min_ratio:.0%} del target "
            f"({target_rate_rps:.3f} r/s) — sin coordinated omission"
        )
    else:
        reason = (
            f"arrival_rate ({actual:.3f} r/s) cayó {(1-ratio)*100:.1f}% bajo "
            f"el target ({target_rate_rps:.3f} r/s). Ronda INVALID — reemplazar seed."
        )
    return CoordinatedOmissionVerdict(
        phase=phase,
        target_rate_rps=target_rate_rps,
        actual_rate_rps=actual,
        ratio=ratio,
        threshold=min_ratio,
        valid=valid,
        reason=reason,
    )
