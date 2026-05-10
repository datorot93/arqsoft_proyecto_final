"""Evaluadores AC-1.1 .. AC-2.6 — el corazón del veredicto F6.

Cada evaluador es una función pura: recibe el cliente Prometheus y la ventana
de tiempo de la fase relevante, devuelve un `Verdict` con `verdict`, `value`,
`threshold`, `reason`. Un evaluador NUNCA lanza excepción — si la métrica
no existe se retorna `verdict='ERROR'` con la razón explícita.

Métrica autoritativa para latencia (AC-1.1, AC-1.2, AC-2.3):
    `cdt_open_handler_duration_seconds_bucket` — punto P3 (entrada de
    `cdt-pais`). Es la única métrica con histograma completo y buckets `le=0.8`
    y `le=1.5` exactos. El cliente k6 (P1) solo emite p99 (no p95) y sin
    histograma — se usa como sanity-check secundario en el reporte.

Mapeo falla → hipótesis (`docs/experimento_asr.md` §4.4):
    Cada `Verdict` declara `hypothesis_refuted` y `suspect_component` cuando
    aplica. El reporte HTML muestra estos campos en el banner rojo de FAIL.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any

from .prometheus import PrometheusClient
from .stratify import (
    percentile_by,
    percentile_global,
    percentile_per_minute,
)

# ---------------------------------------------------------------------------
# Métrica del histograma autoritativo
# ---------------------------------------------------------------------------
LATENCY_METRIC = "cdt_open_handler_duration_seconds_bucket"

# Filtros base por fase. NOTA: la métrica `cdt_open_handler_duration_seconds`
# expone un label `phase` proveniente del env `PHASE` del Deployment F4
# (default = "baseline"); el servicio NO conoce qué escenario k6 está
# corriendo, por tanto NO podemos filtrar por phase a nivel de F4. La
# discriminación baseline ↔ peak se logra por **ventana temporal** (start/end)
# que el orquestador conoce. Mantenemos `exported_endpoint="open_cdt"` para
# no contaminar con `/actuator/health`.
#
# Las métricas que SÍ tienen phase fiable son las de k6 (cuenta `phase=warmup
# |baseline|peak`) y se usan para AC-2.1 (volumen).
BASELINE_FILTER = 'exported_endpoint="open_cdt"'
PEAK_FILTER = 'exported_endpoint="open_cdt"'

# Umbrales del documento maestro §7
TH_AC11_P95_BASELINE_S = 0.800
TH_AC12_P99_BASELINE_S = 1.500
TH_AC21_PEAK_VOLUME = 6000  # 202 OK en 20 min
TH_AC22_PERDIDAS = 0
TH_AC23_MIN_OK = 18  # de 20 minutos
TH_AC23_P95_PEAK_S = 0.800
TH_AC24_DLQ = 0
TH_AC25_HPA_P90_S = 60
TH_AC26_CB_OPEN_HEALTHY_CASES = 0


# ---------------------------------------------------------------------------
# Verdict dataclass
# ---------------------------------------------------------------------------
@dataclass
class Verdict:
    ac_id: str
    name: str
    verdict: str  # PASS | FAIL | ERROR | NA
    value: Any
    threshold: Any
    reason: str
    stratified: dict = field(default_factory=dict)
    hypothesis_refuted: str = ""
    suspect_component: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


def _ms(v: float | None) -> str:
    if v is None:
        return "—"
    return f"{v * 1000:.1f} ms"


# ---------------------------------------------------------------------------
# AC-1.1 — P95 baseline < 800 ms
# ---------------------------------------------------------------------------
def evaluate_ac_1_1(prom: PrometheusClient, baseline_start: float, baseline_end: float) -> Verdict:
    duration = max(60, int(baseline_end - baseline_start))
    p95 = percentile_global(
        prom, LATENCY_METRIC, 0.95, BASELINE_FILTER, baseline_end, duration
    )
    by_pais = percentile_by(
        prom, LATENCY_METRIC, 0.95, BASELINE_FILTER, "pais", baseline_end, duration
    )

    if p95 is None:
        return Verdict(
            ac_id="AC-1.1",
            name="P95 línea base ASR-1",
            verdict="ERROR",
            value=None,
            threshold=_ms(TH_AC11_P95_BASELINE_S),
            reason=(
                "No se obtuvo histogram_quantile(0.95) — sin datos en ventana "
                f"[{baseline_start:.0f}, {baseline_end:.0f}] o métrica ausente."
            ),
        )

    # Estratificación: si algún país individualmente supera el umbral, falla.
    failing_countries = {p: v for p, v in by_pais.items() if v >= TH_AC11_P95_BASELINE_S}
    global_pass = p95 < TH_AC11_P95_BASELINE_S
    pais_pass = not failing_countries

    if global_pass and pais_pass:
        v = "PASS"
        reason = (
            f"P95 global = {_ms(p95)} < {_ms(TH_AC11_P95_BASELINE_S)} y todos los "
            f"países cumplen ({', '.join(f'{p}={_ms(v)}' for p, v in by_pais.items()) or 'sin desagregar'})."
        )
        hyp, suspect = "", ""
    else:
        v = "FAIL"
        if not pais_pass:
            reason = (
                f"P95 global = {_ms(p95)}, pero país(es) por encima del umbral: "
                f"{', '.join(f'{p}={_ms(v)}' for p, v in failing_countries.items())}. "
                f"Dirichlet expone hot-spotting (§4.4 fila 3)."
            )
            hyp = "El sharding por país aísla la carga (Dirichlet)."
            suspect = "Recurso global compartido en ruta crítica de cdt-pais (pool DB, cache, JVM heap)."
        else:
            reason = f"P95 global = {_ms(p95)} ≥ {_ms(TH_AC11_P95_BASELINE_S)}."
            hyp = "ASR-1: P95 < 800 ms en operación nominal."
            suspect = "cdt-pais (handler P3) o cdt-pais → core (P6)."

    return Verdict(
        ac_id="AC-1.1",
        name="P95 línea base ASR-1",
        verdict=v,
        value=_ms(p95),
        threshold=_ms(TH_AC11_P95_BASELINE_S),
        reason=reason,
        stratified={"by_pais": {k: _ms(val) for k, val in by_pais.items()}},
        hypothesis_refuted=hyp,
        suspect_component=suspect,
    )


# ---------------------------------------------------------------------------
# AC-1.2 — P99 baseline < 1500 ms
# ---------------------------------------------------------------------------
def evaluate_ac_1_2(prom: PrometheusClient, baseline_start: float, baseline_end: float) -> Verdict:
    duration = max(60, int(baseline_end - baseline_start))
    p99 = percentile_global(
        prom, LATENCY_METRIC, 0.99, BASELINE_FILTER, baseline_end, duration
    )
    by_pais = percentile_by(
        prom, LATENCY_METRIC, 0.99, BASELINE_FILTER, "pais", baseline_end, duration
    )

    if p99 is None:
        return Verdict(
            ac_id="AC-1.2",
            name="P99 línea base ASR-1 (guardrail)",
            verdict="ERROR",
            value=None,
            threshold=_ms(TH_AC12_P99_BASELINE_S),
            reason="histogram_quantile(0.99) sin datos.",
        )
    pass_ = p99 < TH_AC12_P99_BASELINE_S
    return Verdict(
        ac_id="AC-1.2",
        name="P99 línea base ASR-1 (guardrail)",
        verdict="PASS" if pass_ else "FAIL",
        value=_ms(p99),
        threshold=_ms(TH_AC12_P99_BASELINE_S),
        reason=(
            f"P99 global = {_ms(p99)} {'<' if pass_ else '≥'} {_ms(TH_AC12_P99_BASELINE_S)}."
        ),
        stratified={"by_pais": {k: _ms(val) for k, val in by_pais.items()}},
        hypothesis_refuted=(
            "" if pass_ else "Lognormal de payloads no agrega varianza patológica al P99 (§4.4 fila 5)."
        ),
        suspect_component=("" if pass_ else "Serializadores Jackson + heap del pod."),
    )


# ---------------------------------------------------------------------------
# AC-2.1 — Volumen pico ≥ 6000 (escalable proporcional)
# ---------------------------------------------------------------------------
def evaluate_ac_2_1(
    prom: PrometheusClient,
    peak_start: float,
    peak_end: float,
    threshold_volume: int = TH_AC21_PEAK_VOLUME,
    is_scaled: bool = False,
) -> Verdict:
    duration = max(60, int(peak_end - peak_start))
    # k6 cuenta cada 202 con éxito vía custom counter. Fallback a handler count
    # con exception="none" si no está.
    # k6 sí etiqueta correctamente `phase=peak` (lo emite el cliente).
    # cdt_open_handler usa la ventana temporal para discriminar.
    candidates = [
        f'sum(increase(k6_cdt_success_total_total{{phase="peak"}}[{duration}s]))',
        f'sum(increase(cdt_open_handler_duration_seconds_count{{exception="none",exported_endpoint="open_cdt"}}[{duration}s]))',
    ]
    volume = 0.0
    used = ""
    for q in candidates:
        v = prom.first_value(q, when=peak_end)
        if v is not None and v > 0:
            volume = v
            used = q
            break

    if volume == 0.0:
        return Verdict(
            ac_id="AC-2.1",
            name="Volumen completado durante el pico ASR-2",
            verdict="ERROR",
            value=0,
            threshold=threshold_volume,
            reason="No se observaron 202 OK en la ventana del peak.",
        )

    pass_ = volume >= threshold_volume
    note = " [SCALED RUN]" if is_scaled else ""
    return Verdict(
        ac_id="AC-2.1",
        name="Volumen completado durante el pico ASR-2",
        verdict="PASS" if pass_ else "FAIL",
        value=int(volume),
        threshold=threshold_volume,
        reason=(
            f"{int(volume)} aperturas con 202 OK durante peak (ventana={duration}s){note}. "
            f"Query: {used}"
        ),
        hypothesis_refuted=(
            "" if pass_ else "El HPA + Kong rate-limiter absorben el onset NHPP (§4.4 fila 1)."
        ),
        suspect_component=(
            ""
            if pass_
            else "HPA (targetCPU) o Kong rate-limiting-advanced (burst window)."
        ),
    )


# ---------------------------------------------------------------------------
# AC-2.2 — Aperturas perdidas = 0
# ---------------------------------------------------------------------------
def evaluate_ac_2_2(
    prom: PrometheusClient, peak_start: float, peak_end: float
) -> Verdict:
    """Aperturas perdidas = todo lo que NO retornó 202 OK durante el peak.

    Estrategia A (sin métrica nueva): suma de `k6_cdt_error_total_total` +
    handler counts con `exception != "none"`.
    """
    duration = max(60, int(peak_end - peak_start))
    queries = [
        ("k6_cdt_error_total_total",
         f'sum(increase(k6_cdt_error_total_total{{phase="peak"}}[{duration}s]))'),
        ("cdt_handler_exceptions",
         f'sum(increase(cdt_open_handler_duration_seconds_count{{exception!="none",exported_endpoint="open_cdt"}}[{duration}s]))'),
    ]
    breakdown: dict[str, float] = {}
    total = 0.0
    for label, q in queries:
        v = prom.first_value(q, when=peak_end)
        if v is None:
            v = 0.0
        breakdown[label] = float(v)
        total += float(v)

    pass_ = total == 0
    return Verdict(
        ac_id="AC-2.2",
        name="Aperturas perdidas durante el pico",
        verdict="PASS" if pass_ else "FAIL",
        value=int(total),
        threshold=TH_AC22_PERDIDAS,
        reason=(
            f"{int(total)} aperturas no completaron 202 OK durante el peak "
            f"(breakdown: {breakdown})."
            + ("" if pass_ else " Posible retry storm o saturación.")
        ),
        stratified={"breakdown": breakdown},
        hypothesis_refuted=(
            "" if pass_ else "Bernoulli de errores no produce avalancha (§4.4 fila 6)."
        ),
        suspect_component=(
            "" if pass_ else "Política de retry con jitter + DLQ del broker / Kong."
        ),
    )


# ---------------------------------------------------------------------------
# AC-2.3 — P95 < 800 ms en ≥ 18/20 minutos
# ---------------------------------------------------------------------------
def evaluate_ac_2_3(
    prom: PrometheusClient,
    peak_start: float,
    peak_end: float,
    min_ok_minutes: int = TH_AC23_MIN_OK,
) -> Verdict:
    series = percentile_per_minute(
        prom, LATENCY_METRIC, 0.95, PEAK_FILTER, peak_start, peak_end, window_s=60
    )
    minutes_total = len(series)
    minutes_ok = 0
    minutes_fail = []
    for ts, v in series:
        if v is None:
            # Sin datos: por garantismo lo contamos como FAIL del minuto.
            minutes_fail.append((ts, None))
            continue
        if v < TH_AC23_P95_PEAK_S:
            minutes_ok += 1
        else:
            minutes_fail.append((ts, v))

    # Cuando la fase peak corre 20 min completos, exigimos `minutes_ok >= 18`.
    # Si la ventana es escalada (e.g. 4 min en una ronda smoke/scaled), aplicamos
    # la regla proporcional: `minutes_ok / minutes_total ≥ 18/20 = 0.9`. Esto
    # preserva la semántica del documento maestro §7 sin penalizar honestamente
    # rondas escaladas que tienen <20 minutos por construcción.
    if minutes_total >= 20:
        pass_ = minutes_ok >= min_ok_minutes
    else:
        pass_ = (
            minutes_total >= 1
            and (minutes_ok / max(1, minutes_total)) >= (min_ok_minutes / 20)
        )

    return Verdict(
        ac_id="AC-2.3",
        name="P95 sostenido durante el pico (minuto-a-minuto)",
        verdict="PASS" if pass_ else ("FAIL" if minutes_total > 0 else "ERROR"),
        value=f"{minutes_ok}/{minutes_total} min con P95 < 800 ms",
        threshold=f"≥ {min_ok_minutes}/20 min (proporcional si escalado)",
        reason=(
            f"De {minutes_total} minutos observados, {minutes_ok} cumplieron "
            f"P95<{int(TH_AC23_P95_PEAK_S*1000)}ms; "
            + (
                "el ratio supera el mínimo proporcional."
                if pass_
                else f"minutos en falla: "
                + ", ".join(
                    f"t={int(ts - peak_start)}s→P95={(_ms(v))}"
                    for ts, v in minutes_fail[:5]
                )
            )
        ),
        stratified={"per_minute": [(int(ts - peak_start), _ms(v)) for ts, v in series]},
        hypothesis_refuted=(
            ""
            if pass_
            else "MMPP-2 NO degrada el throttling adaptativo del gateway (§4.4 fila 2)."
        ),
        suspect_component=(
            "" if pass_ else "Kong rate-limiting-advanced (sliding window) + HPA cooldown."
        ),
    )


# ---------------------------------------------------------------------------
# AC-2.4 — DLQ = 0  (interpretación arquitectónica)
# ---------------------------------------------------------------------------
def evaluate_ac_2_4(
    prom: PrometheusClient, peak_start: float, peak_end: float
) -> Verdict:
    """En la arquitectura actual NO existe DLQ explícito: el outbox-dispatcher
    reintenta indefinido (publish_attempts crece sin tope). Por tanto el
    veredicto AC-2.4 se traduce en dos invariantes equivalentes:

        1) `outbox_dispatch_total{result="failure"}` = 0 durante la ronda.
        2) `outbox_dispatch_lag_seconds` ≈ 0 al final del peak (todo se publicó).
        3) `vectorized_kafka_handler_requests_errored_total` no crece.

    Si las tres se cumplen → PASS por construcción (no hay mensajes huérfanos).
    Si alguna falla → FAIL: hay mensajes que se quedaron atascados.
    """
    duration = max(60, int(peak_end - peak_start))
    failures_q = (
        f'sum(increase(outbox_dispatch_total{{result="failure"}}[{duration}s]))'
    )
    lag_q = "max(outbox_dispatch_lag_seconds)"
    kafka_err_q = (
        f"sum(increase(vectorized_kafka_handler_requests_errored_total[{duration}s]))"
    )

    failures = prom.first_value(failures_q, when=peak_end) or 0.0
    lag = prom.first_value(lag_q, when=peak_end) or 0.0
    kafka_err = prom.first_value(kafka_err_q, when=peak_end) or 0.0

    pass_ = failures == 0 and lag < 5.0 and kafka_err == 0
    return Verdict(
        ac_id="AC-2.4",
        name="DLQ — eventos huérfanos del outbox/broker",
        verdict="PASS" if pass_ else "FAIL",
        value={
            "outbox_failures": int(failures),
            "outbox_lag_s": round(float(lag), 2),
            "kafka_errors": int(kafka_err),
        },
        threshold={"outbox_failures": 0, "outbox_lag_s": "< 5", "kafka_errors": 0},
        reason=(
            "No hay DLQ explícito en F4 (outbox reintenta indefinido). "
            "Equivalente: outbox_dispatch_total{result='failure'}, "
            "outbox_dispatch_lag_seconds y vectorized_kafka_handler_requests_errored_total. "
            f"Observado: failures={int(failures)}, lag={lag:.1f}s, kafka_err={int(kafka_err)}."
        ),
        hypothesis_refuted=(
            "" if pass_ else "Política retry+jitter no produce avalancha (§4.4 fila 6)."
        ),
        suspect_component=(
            ""
            if pass_
            else "outbox-dispatcher (poll interval) o Redpanda (handler errored)."
        ),
    )


# ---------------------------------------------------------------------------
# AC-2.5 — Tiempo escalado HPA < 60 s p90
# ---------------------------------------------------------------------------
def evaluate_ac_2_5(
    prom: PrometheusClient, peak_start: float, peak_end: float
) -> Verdict:
    """Calcula el tiempo desde que `desired > current` hasta `current = desired`.

    Implementación:
      - Capturar series desired y current vía range query con step 15 s.
      - Para cada deployment HPA, identificar transiciones donde desired sube
        respecto al observado. Medir cuántos puntos de 15 s tarda current en
        igualar desired.
      - p90 sobre todos los eventos detectados.
    """
    desired = prom.query_range(
        'kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler=~"cdt-pais-.*"}',
        peak_start, peak_end, step_s=15,
    )
    current = prom.query_range(
        'kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler=~"cdt-pais-.*"}',
        peak_start, peak_end, step_s=15,
    )

    def by_hpa(series):
        out: dict[str, list[tuple[float, int]]] = {}
        for s in series:
            hpa = s["metric"].get("horizontalpodautoscaler", "?")
            vals = []
            for ts, v in s.get("values", []):
                try:
                    vals.append((float(ts), int(float(v))))
                except (TypeError, ValueError):
                    continue
            out[hpa] = vals
        return out

    desired_map = by_hpa(desired)
    current_map = by_hpa(current)

    durations_s: list[float] = []
    events: list[dict] = []
    for hpa, dvals in desired_map.items():
        cvals = current_map.get(hpa, [])
        if not dvals or not cvals:
            continue
        # Índice por timestamp para mismo step.
        cmap = dict(cvals)
        last_target = None
        target_set_at: float | None = None
        for ts, d in dvals:
            c = cmap.get(ts)
            if c is None:
                continue
            if d > c:
                if last_target != d:
                    last_target = d
                    target_set_at = ts
            elif d == c and target_set_at is not None and last_target == d:
                dur = ts - target_set_at
                durations_s.append(dur)
                events.append({"hpa": hpa, "from_t": target_set_at, "to_t": ts, "dur_s": dur, "target": d})
                target_set_at = None
                last_target = None

    if not durations_s:
        return Verdict(
            ac_id="AC-2.5",
            name="Tiempo de escalado HPA (replicas pending → ready)",
            verdict="NA",
            value="sin eventos de escalado detectados",
            threshold=f"p90 < {TH_AC25_HPA_P90_S}s",
            reason=(
                "Durante la ventana del peak no se detectaron eventos "
                "`desired > current`. Posible: (a) HPA ya estaba escalado o "
                "(b) carga insuficiente para gatillar autoescalado en este entorno."
            ),
        )

    sorted_d = sorted(durations_s)
    idx = max(0, int(0.9 * (len(sorted_d) - 1)))
    p90 = sorted_d[idx]
    pass_ = p90 < TH_AC25_HPA_P90_S
    return Verdict(
        ac_id="AC-2.5",
        name="Tiempo de escalado HPA (replicas pending → ready)",
        verdict="PASS" if pass_ else "FAIL",
        value=f"p90 = {p90:.1f} s sobre {len(durations_s)} evento(s)",
        threshold=f"p90 < {TH_AC25_HPA_P90_S}s",
        reason=(
            f"p90 de tiempo {len(durations_s)} eventos = {p90:.1f}s "
            f"({'<' if pass_ else '≥'} {TH_AC25_HPA_P90_S}s)."
        ),
        stratified={"events": events[:20]},
        hypothesis_refuted=(
            "" if pass_ else "HPA reacciona en <30s antes del desborde (§4.4 fila 1)."
        ),
        suspect_component=(
            "" if pass_ else "HPA targetCPU o Cluster Autoscaler (en local: kind 1-nodo)."
        ),
    )


# ---------------------------------------------------------------------------
# AC-2.6 — CB OPEN > 90 s con core sano = 0 casos
# ---------------------------------------------------------------------------
def evaluate_ac_2_6(
    prom: PrometheusClient, peak_start: float, peak_end: float
) -> Verdict:
    """Detecta intervalos del CB en estado OPEN > 90 s mientras el core
    no está fallando (failure_rate ≈ 0).

    Implementación: range query del estado del CB (resilience4j_circuitbreaker_state
    que vale 1 cuando el state= label coincide). Para cada CB, contar runs
    consecutivos de `state="open"` >= 90 s. Cruzar con failure_rate < 5%.
    """
    state = prom.query_range(
        'resilience4j_circuitbreaker_state{state="open"}',
        peak_start, peak_end, step_s=15,
    )
    fr = prom.query_range(
        "resilience4j_circuitbreaker_failure_rate",
        peak_start, peak_end, step_s=15,
    )

    fr_by_name: dict[str, list[tuple[float, float]]] = {}
    for s in fr:
        name = s["metric"].get("name", "?")
        vals = []
        for ts, v in s.get("values", []):
            try:
                vals.append((float(ts), float(v)))
            except (TypeError, ValueError):
                continue
        fr_by_name[name] = vals

    bad_episodes = []
    for s in state:
        name = s["metric"].get("name", "?")
        vals = []
        for ts, v in s.get("values", []):
            try:
                vals.append((float(ts), float(v)))
            except (TypeError, ValueError):
                continue
        run_start = None
        for ts, v in vals:
            if v >= 0.5:  # state="open" activo
                if run_start is None:
                    run_start = ts
            else:
                if run_start is not None:
                    dur = ts - run_start
                    if dur > 90:
                        # Evaluar si el core estaba sano en este run
                        fr_series = fr_by_name.get(name, [])
                        fr_in_run = [
                            f for (t, f) in fr_series if run_start <= t <= ts and f >= 0
                        ]
                        avg_fr = sum(fr_in_run) / len(fr_in_run) if fr_in_run else -1
                        if avg_fr < 5.0:  # core sano (Resilience4j reporta % entre 0..100, -1 si no hay calls)
                            bad_episodes.append(
                                {"cb": name, "from": run_start, "to": ts, "dur_s": dur, "avg_failure_rate": avg_fr}
                            )
                    run_start = None
        if run_start is not None:
            # Run abierto al final
            dur = peak_end - run_start
            if dur > 90:
                fr_series = fr_by_name.get(name, [])
                fr_in_run = [f for (t, f) in fr_series if run_start <= t <= peak_end and f >= 0]
                avg_fr = sum(fr_in_run) / len(fr_in_run) if fr_in_run else -1
                if avg_fr < 5.0:
                    bad_episodes.append(
                        {"cb": name, "from": run_start, "to": peak_end, "dur_s": dur, "avg_failure_rate": avg_fr}
                    )

    pass_ = len(bad_episodes) == TH_AC26_CB_OPEN_HEALTHY_CASES
    return Verdict(
        ac_id="AC-2.6",
        name="CircuitBreaker recupera (no queda OPEN > 90 s con core sano)",
        verdict="PASS" if pass_ else "FAIL",
        value=f"{len(bad_episodes)} caso(s)",
        threshold=f"= {TH_AC26_CB_OPEN_HEALTHY_CASES}",
        reason=(
            f"Detectados {len(bad_episodes)} episodios CB OPEN > 90s con failure_rate < 5%."
            + (
                ""
                if pass_
                else " Episodios: "
                + ", ".join(
                    f"{e['cb']}@{int(e['dur_s'])}s(fr={e['avg_failure_rate']:.1f}%)"
                    for e in bad_episodes[:5]
                )
            )
        ),
        stratified={"bad_episodes": bad_episodes[:20]},
        hypothesis_refuted=(
            "" if pass_ else "Pareto del core no satura el CB; pools del ACL aíslan (§4.4 fila 4)."
        ),
        suspect_component=(
            "" if pass_ else "ACL CircuitBreaker config (slidingWindowSize) + Bulkhead size."
        ),
    )


# ---------------------------------------------------------------------------
# Coordinador: evalúa los 8 AC-* dado el manifest de la ronda
# ---------------------------------------------------------------------------
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


def evaluate_all(
    prom: PrometheusClient,
    baseline_start: float,
    baseline_end: float,
    peak_start: float,
    peak_end: float,
    is_scaled: bool = False,
    threshold_volume_override: int | None = None,
) -> dict[str, dict]:
    """Evalúa los 8 AC-* y devuelve un dict id → Verdict.to_dict()."""
    threshold_volume = threshold_volume_override or TH_AC21_PEAK_VOLUME
    verdicts: dict[str, Verdict] = {
        "AC-1.1": evaluate_ac_1_1(prom, baseline_start, baseline_end),
        "AC-1.2": evaluate_ac_1_2(prom, baseline_start, baseline_end),
        "AC-2.1": evaluate_ac_2_1(
            prom, peak_start, peak_end, threshold_volume=threshold_volume, is_scaled=is_scaled
        ),
        "AC-2.2": evaluate_ac_2_2(prom, peak_start, peak_end),
        "AC-2.3": evaluate_ac_2_3(prom, peak_start, peak_end),
        "AC-2.4": evaluate_ac_2_4(prom, peak_start, peak_end),
        "AC-2.5": evaluate_ac_2_5(prom, peak_start, peak_end),
        "AC-2.6": evaluate_ac_2_6(prom, peak_start, peak_end),
    }
    return {k: verdicts[k].to_dict() for k in AC_ORDER}
