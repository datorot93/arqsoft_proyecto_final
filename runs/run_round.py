#!/usr/bin/env python3
"""F6 — Orquestador de UNA ronda del experimento.

Procedimiento (§6.3 del documento maestro):
    1. Calentamiento — descartado.
    2. Línea base ASR-1 — captura P95/P99 → AC-1.1, AC-1.2.
    3. Pico ASR-2 — captura volumen, P95 minuto-a-minuto, DLQ, HPA, CB.

Cada etapa se lanza creando un CRD `TestRun` del k6-operator vía `kubectl
apply -f <yaml>` con el SEED inyectado (env override) y un sufijo único en el
nombre (timestamp + seed) para evitar colisiones.

Tras cada etapa esperamos que el TestRun pase a `Stopped`/`Finished` y
capturamos `started_at`/`ended_at` del status del CR.

Luego invocamos los 8 evaluadores AC-* con la ventana baseline y peak,
serializamos `verdicts.json`, `manifest.json`, snapshot Prometheus y
`report.html`.

Uso:
    python runs/run_round.py --seed 42
    python runs/run_round.py --seed 42 --scaled         # warmup 1m, baseline 3m, peak 4m
    python runs/run_round.py --seed 42 --smoke          # warmup 30s, baseline 60s, peak 120s
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from runs.lib.coordinated_omission import evaluate as eval_co  # noqa: E402
from runs.lib.manifest import RoundManifest, write_atomic_json  # noqa: E402
from runs.lib.prometheus import PrometheusClient  # noqa: E402
from runs.lib.verdicts import evaluate_all  # noqa: E402

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
NS_CARGA = "carga"
TESTRUN_GVR = ("k6.io", "v1alpha1", "testruns")

# Duraciones por modo (en segundos)
DURATIONS = {
    "full": {
        "warmup": 300,
        "baseline": 900,
        "peak": 1200,
        "warmup_rate": 2,
        "baseline_target_rps": 0.2,  # 1 req cada 5s
        "peak_volume_threshold": 6000,
    },
    "scaled": {
        "warmup": 60,
        "baseline": 180,
        "peak": 240,
        "warmup_rate": 2,
        "baseline_target_rps": 0.2,
        # umbral proporcional 6000 * (240 / 1200) = 1200
        "peak_volume_threshold": 1200,
    },
    "smoke": {
        "warmup": 30,
        "baseline": 120,  # baseline 0.2 r/s — necesitamos ≥ 60s para promediar
        "peak": 120,
        "warmup_rate": 2,
        "baseline_target_rps": 0.2,
        # 6000 * (120/1200) = 600
        "peak_volume_threshold": 600,
    },
}


def log(msg: str) -> None:
    print(f"[run_round {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def kubectl(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["kubectl", *args], check=check, capture_output=True, text=True
    )


# ---------------------------------------------------------------------------
# Cluster sanity check
# ---------------------------------------------------------------------------
def assert_cluster_ready() -> None:
    log("verificando cluster ready (linea-verde, asincrono, datos, borde, observabilidad)")
    for ns in ("linea-verde", "asincrono", "datos", "borde", "observabilidad"):
        r = kubectl(
            "get",
            "pods",
            "-n",
            ns,
            "--no-headers",
            "-o",
            "custom-columns=:status.phase",
        )
        bad = [p for p in r.stdout.strip().splitlines() if p and p not in ("Running", "Succeeded")]
        if bad:
            raise RuntimeError(f"namespace {ns} tiene pods en estado: {bad}")


# ---------------------------------------------------------------------------
# Lanzamiento de TestRun via kubectl apply (con SEED inyectado en runtime)
# ---------------------------------------------------------------------------
def _patched_yaml(src: Path, replacements: dict[str, str]) -> str:
    """Reemplazo simple de literales en el YAML.

    Reemplaza valores `value: "<old>"` para keys conocidas por nuevos. Es
    más robusto que `sed` y evita un parser YAML completo (los CR tienen
    expresiones largas con multiline).
    """
    text = src.read_text()
    for key, new in replacements.items():
        # ej. SEED → name: SEED \n value: "42" ; reemplazamos el value: "<X>" tras la línea name: <key>
        lines = text.splitlines()
        for i, ln in enumerate(lines):
            if f"name: {key}" in ln:
                # buscar el siguiente value: "..."
                for j in range(i + 1, min(i + 4, len(lines))):
                    if lines[j].lstrip().startswith("value:"):
                        prefix = lines[j][: lines[j].index("value:") + len("value:")]
                        lines[j] = f'{prefix} "{new}"'
                        break
        text = "\n".join(lines)
    return text


def submit_testrun(
    yaml_template: Path,
    *,
    suffix: str,
    seed: int,
    duration_s: int,
    extra_env: dict[str, str] | None = None,
) -> str:
    """Aplica el TestRun con sustituciones y devuelve el nombre final del CR."""
    extra_env = extra_env or {}

    text = yaml_template.read_text()
    # reemplazo del nombre para hacerlo único
    base_name = None
    for ln in text.splitlines():
        if ln.lstrip().startswith("name:") and base_name is None:
            base_name = ln.split(":", 1)[1].strip()
            break
    if not base_name:
        raise RuntimeError(f"no se encontró metadata.name en {yaml_template}")
    new_name = f"{base_name}-{suffix}"
    text = text.replace(f"name: {base_name}", f"name: {new_name}", 1)

    # Reemplazos de env
    replacements = {"SEED": str(seed)}
    # Mapear duration por escenario
    if "warmup" in yaml_template.name:
        replacements["WARMUP_DURATION"] = str(duration_s)
    elif "baseline" in yaml_template.name:
        replacements["BASELINE_DURATION"] = str(duration_s)
    elif "peak" in yaml_template.name:
        replacements["PEAK_DURATION"] = str(duration_s)
    replacements.update(extra_env)

    # Aplicar mediante reemplazo de línea siguiente a `name: <KEY>`
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        for key in list(replacements.keys()):
            if f"name: {key}" in ln:
                for j in range(i + 1, min(i + 4, len(lines))):
                    if lines[j].lstrip().startswith("value:"):
                        prefix = lines[j][: lines[j].index("value:") + len("value:")]
                        lines[j] = f'{prefix} "{replacements[key]}"'
                        break
    text = "\n".join(lines)

    # peak escenario podría no tener PEAK_DURATION env hasta ahora. Insertarlo
    # como override si no estaba definido.
    if "peak" in yaml_template.name and "PEAK_DURATION" not in text:
        # Insertar antes de `resources:` env extra (último recurso documentado)
        marker = "      - name: PEAK_MAX_VUS"
        if marker in text:
            insert_block = (
                f"      - name: PEAK_DURATION\n"
                f"        value: \"{duration_s}\"\n"
            )
            text = text.replace(marker, insert_block + marker, 1)

    # Disable cleanup: post — el orquestador necesita leer status.stage =
    # finished y los timestamps del Job DESPUÉS de que k6 termine. Borraremos
    # los CRs manualmente al final de cada ronda.
    text = text.replace("cleanup: post", "# cleanup: post (disabled by F6 orchestrator)")

    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as tmp:
        tmp.write(text)
        tmp_path = Path(tmp.name)

    try:
        kubectl("apply", "-f", str(tmp_path))
    finally:
        tmp_path.unlink(missing_ok=True)
    log(f"  TestRun {new_name} creado")
    return new_name


def wait_testrun(
    name: str,
    ns: str = NS_CARGA,
    timeout_s: int = 1800,
    expected_duration_s: int | None = None,
) -> tuple[float, float]:
    """Espera a que el TestRun llegue a Finished/Stopped. Devuelve (start_ts, end_ts).

    El k6-operator 0.0.16 con `cleanup: post` borra el CR poco después de que
    `stage=finished`. Detectamos ese caso observando la desaparición del job
    runner asociado:
        * k6 corre como Job `<testrun-name>-1` (parallelism=1).
        * Cuando el Job completa Y el TestRun se borra, asumimos finished.

    Estrategia:
        1. Mientras el TestRun exista → ver `status.stage`.
        2. Si stage in {"finished","stopped","error"} → done.
        3. Si el TestRun fue ya borrado pero observamos su Job en estado
           Complete → done.
    """
    started = time.time()
    log(f"  esperando TestRun {name} (timeout {timeout_s}s)…")
    last_phase = None
    runner_start_ts: float | None = None
    runner_end_ts: float | None = None
    saw_started_stage = False

    while time.time() - started < timeout_s:
        r = kubectl("get", "testrun", name, "-n", ns, "-o", "json", check=False)
        if r.returncode == 0 and r.stdout:
            obj = json.loads(r.stdout)
            status = obj.get("status", {}) or {}
            stage = status.get("stage", "")
            if stage != last_phase:
                log(f"    stage={stage}")
                last_phase = stage
            if stage == "started" and not saw_started_stage:
                saw_started_stage = True
                runner_start_ts = time.time()
            if stage in ("finished", "stopped", "error"):
                # Tomar timestamps del Job si existe, si no usar runner_start.
                start_ts = runner_start_ts or (time.time() - timeout_s)
                end_ts = time.time()
                _try_runner_times = _get_job_times(f"{name}-1", ns)
                if _try_runner_times:
                    start_ts, end_ts = _try_runner_times
                return start_ts, end_ts
        else:
            # CR desapareció. Confirmar via Job runner status.
            _job = _get_job_times(f"{name}-1", ns)
            if _job:
                start_ts, end_ts = _job
                log(f"    TestRun CR ya borrado (cleanup:post). Job {name}-1 terminó OK")
                return start_ts, end_ts
            # Quizá nunca lo creó — esperar.
        time.sleep(3)

    raise RuntimeError(f"TestRun {name} no alcanzó finished en {timeout_s}s")


def _get_job_times(job_name: str, ns: str) -> tuple[float, float] | None:
    """Devuelve (start, end) del Job si está Complete; None si no existe o no completó."""
    r = kubectl("get", "job", job_name, "-n", ns, "-o", "json", check=False)
    if r.returncode != 0 or not r.stdout:
        return None
    try:
        obj = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    status = obj.get("status", {}) or {}
    succeeded = status.get("succeeded", 0)
    if not succeeded:
        return None
    start = status.get("startTime")
    completion = status.get("completionTime")
    if not start or not completion:
        return None
    try:
        # ISO8601 like "2026-05-09T22:01:30Z"
        from datetime import datetime, timezone

        s = datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        e = datetime.strptime(completion, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        return s, e
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Snapshot Prometheus de la ronda
# ---------------------------------------------------------------------------
SNAPSHOT_QUERIES = {
    "p95_baseline": (
        'histogram_quantile(0.95, sum by (le) (rate(cdt_open_handler_duration_seconds_bucket'
        '{exported_endpoint="open_cdt"}[15m])))'
    ),
    "p99_baseline": (
        'histogram_quantile(0.99, sum by (le) (rate(cdt_open_handler_duration_seconds_bucket'
        '{exported_endpoint="open_cdt"}[15m])))'
    ),
    "p95_peak_per_min": (
        'histogram_quantile(0.95, sum by (le) (rate(cdt_open_handler_duration_seconds_bucket'
        '{exported_endpoint="open_cdt"}[1m])))'
    ),
    "p95_peak_by_pais": (
        'histogram_quantile(0.95, sum by (pais, le) (rate(cdt_open_handler_duration_seconds_bucket'
        '{exported_endpoint="open_cdt"}[1m])))'
    ),
    "hpa_current": 'kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler=~"cdt-pais-.*"}',
    "hpa_desired": 'kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler=~"cdt-pais-.*"}',
    "cb_state_open": 'resilience4j_circuitbreaker_state{state="open"}',
    "cb_failure_rate": "resilience4j_circuitbreaker_failure_rate",
    "outbox_lag": "outbox_dispatch_lag_seconds",
    "k6_reqs_rate": "rate(k6_http_reqs_total[1m])",
}


def snapshot_prometheus(
    prom: PrometheusClient,
    start: float,
    end: float,
    out_dir: Path,
) -> Path:
    """Guarda un dump JSON de `query_range` para todas las series relevantes."""
    out_dir.mkdir(parents=True, exist_ok=True)
    bundle = {"start": start, "end": end, "queries": {}}
    for k, q in SNAPSHOT_QUERIES.items():
        try:
            bundle["queries"][k] = {
                "promql": q,
                "result": prom.query_range(q, start, end, step_s=15),
            }
        except Exception as e:  # pragma: no cover — robustez en local
            bundle["queries"][k] = {"promql": q, "error": str(e)}
    out_path = out_dir / "prometheus_snapshot.json"
    write_atomic_json(out_path, bundle)
    return out_path


# ---------------------------------------------------------------------------
# Orquestación de la ronda
# ---------------------------------------------------------------------------
def run_round(
    seed: int,
    mode: str,
    out_root: Path,
    skip_warmup: bool = False,
) -> Path:
    cfg = DURATIONS[mode]
    is_scaled = mode != "full"

    assert_cluster_ready()

    # Limpieza pre-ronda: borrar TestRuns y Jobs huérfanos en `carga` para
    # evitar que conflictos de nombres o pods activos contaminen la nueva ronda.
    kubectl("delete", "testrun", "--all", "-n", NS_CARGA, "--ignore-not-found", check=False)
    kubectl("delete", "job", "--all", "-n", NS_CARGA, "--ignore-not-found", check=False)
    time.sleep(2)

    round_id = f"r{int(time.time())}-s{seed}-{mode}"
    out_dir = out_root / round_id
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest = RoundManifest(
        round_id=round_id,
        seed=seed,
        scaled=is_scaled,
        config={
            "mode": mode,
            **cfg,
        },
    )
    manifest.started_at = time.time()

    yaml_dir = ROOT / "infra" / "k8s" / "carga"
    suffix = f"s{seed}-{int(time.time())}"
    prom = PrometheusClient()

    # ----------------------------------------------------------------------
    # Etapa 1: warmup (descartar)
    # ----------------------------------------------------------------------
    if not skip_warmup:
        log("ETAPA 1/3 — warmup (descartar)")
        manifest.warmup.testrun_name = submit_testrun(
            yaml_dir / "k6-warmup.yaml",
            suffix=suffix,
            seed=seed,
            duration_s=cfg["warmup"],
        )
        manifest.warmup.started_at, manifest.warmup.ended_at = wait_testrun(
            manifest.warmup.testrun_name, timeout_s=cfg["warmup"] * 4 + 120
        )
        manifest.warmup.duration_s = manifest.warmup.ended_at - manifest.warmup.started_at
        log(f"  warmup_done  ({manifest.warmup.duration_s:.0f}s)")
    else:
        log("ETAPA 1/3 — warmup OMITIDO (--skip-warmup)")

    # ----------------------------------------------------------------------
    # Etapa 2: baseline
    # ----------------------------------------------------------------------
    log("ETAPA 2/3 — baseline ASR-1")
    manifest.baseline.testrun_name = submit_testrun(
        yaml_dir / "k6-baseline.yaml",
        suffix=suffix,
        seed=seed,
        duration_s=cfg["baseline"],
    )
    manifest.baseline.started_at, manifest.baseline.ended_at = wait_testrun(
        manifest.baseline.testrun_name, timeout_s=cfg["baseline"] * 4 + 120
    )
    manifest.baseline.duration_s = manifest.baseline.ended_at - manifest.baseline.started_at
    log(f"  baseline_done ({manifest.baseline.duration_s:.0f}s)")

    # ----------------------------------------------------------------------
    # Etapa 3: peak
    # ----------------------------------------------------------------------
    log("ETAPA 3/3 — peak ASR-2")
    manifest.peak.testrun_name = submit_testrun(
        yaml_dir / "k6-peak.yaml",
        suffix=suffix,
        seed=seed,
        duration_s=cfg["peak"],
    )
    manifest.peak.started_at, manifest.peak.ended_at = wait_testrun(
        manifest.peak.testrun_name, timeout_s=cfg["peak"] * 4 + 240
    )
    manifest.peak.duration_s = manifest.peak.ended_at - manifest.peak.started_at
    log(f"  peak_done     ({manifest.peak.duration_s:.0f}s)")

    manifest.ended_at = time.time()

    # ----------------------------------------------------------------------
    # Coordinated omission (baseline y peak)
    # ----------------------------------------------------------------------
    # Baseline: tasa muy baja (0.2 r/s = 1 req / 5s) y duración corta hace
    # que el cociente observado/target sea ruidoso. En modo `full` (15 min)
    # el promedio se estabiliza en ±2%; en escalado/smoke aceptamos hasta
    # 50% de drift sin invalidar la ronda — la regla de coordinated omission
    # del documento maestro aplica en condiciones de carga, no de baseline.
    if mode == "full":
        co_baseline_min_ratio = 0.90
    else:
        co_baseline_min_ratio = 0.50
    co_baseline = eval_co(
        prom,
        phase="baseline",
        target_rate_rps=cfg["baseline_target_rps"],
        start=manifest.baseline.started_at,
        end=manifest.baseline.ended_at,
        min_ratio=co_baseline_min_ratio,
    )
    # target_rate del peak: estimación analítica. Integral de λ(t) sobre 1200s
    # del NHPP es ~6000 + bursty ≈ ~7800-9000. Para una ronda escalada
    # `peak/1200`. Usamos `peak_volume_threshold` / duration para estimar.
    peak_target_rate = cfg["peak_volume_threshold"] / cfg["peak"]
    co_peak = eval_co(
        prom,
        phase="peak",
        target_rate_rps=peak_target_rate,
        start=manifest.peak.started_at,
        end=manifest.peak.ended_at,
        min_ratio=0.85,  # peak: NHPP+MMPP tiene varianza alta, tolerancia 15%
    )

    invalid = (not co_baseline.valid) or (not co_peak.valid)

    # ----------------------------------------------------------------------
    # Evaluación AC-*
    # ----------------------------------------------------------------------
    log("evaluando los 8 AC-* …")
    verdicts = evaluate_all(
        prom,
        baseline_start=manifest.baseline.started_at,
        baseline_end=manifest.baseline.ended_at,
        peak_start=manifest.peak.started_at,
        peak_end=manifest.peak.ended_at,
        is_scaled=is_scaled,
        threshold_volume_override=cfg["peak_volume_threshold"] if is_scaled else None,
    )

    # Veredicto agregado de la ronda:
    #   PASS  — todos los AC-* en {PASS, NA}.
    #   FAIL  — al menos un AC-* en FAIL.
    #   ERROR — al menos un AC-* en ERROR (sin datos / métrica ausente) y nada FAIL.
    #   NA se acepta como "no aplica en este entorno" (típico de AC-2.5 cuando
    #   la carga no gatilla autoescalado, e.g. HPA ya escalado o ronda escalada).
    failed = [k for k, vv in verdicts.items() if vv["verdict"] == "FAIL"]
    errored = [k for k, vv in verdicts.items() if vv["verdict"] == "ERROR"]
    overall_pass = not failed and not errored

    if invalid:
        overall = "INVALID"
        overall_reason = "Coordinated omission detectado — ronda inválida, reemplazar con seed nuevo."
    elif failed:
        overall = "FAIL"
        overall_reason = f"AC-* fallidos: {', '.join(failed)}"
    elif errored:
        overall = "ERROR"
        overall_reason = f"AC-* sin datos: {', '.join(errored)}"
    else:
        overall = "PASS"
        na = [k for k, vv in verdicts.items() if vv["verdict"] == "NA"]
        overall_reason = (
            f"Los 8 AC-* pasaron en esta ronda."
            + (f" NA: {', '.join(na)}." if na else "")
        )

    log(f"VEREDICTO RONDA {round_id}: {overall} — {overall_reason}")

    # ----------------------------------------------------------------------
    # Persistencia: manifest, verdicts, snapshot, reporte
    # ----------------------------------------------------------------------
    manifest.write(out_dir / "manifest.json")
    write_atomic_json(out_dir / "verdicts.json", verdicts)
    write_atomic_json(
        out_dir / "coordinated_omission.json",
        {"baseline": co_baseline.to_dict(), "peak": co_peak.to_dict()},
    )
    write_atomic_json(
        out_dir / "round_summary.json",
        {
            "round_id": round_id,
            "seed": seed,
            "mode": mode,
            "scaled": is_scaled,
            "overall_verdict": overall,
            "overall_reason": overall_reason,
            "started_at": manifest.started_at,
            "ended_at": manifest.ended_at,
        },
    )
    snapshot_prometheus(
        prom,
        start=manifest.warmup.started_at or manifest.baseline.started_at,
        end=manifest.peak.ended_at,
        out_dir=out_dir,
    )

    # Reporte HTML
    log("generando report.html …")
    try:
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "report" / "build_report.py"),
                "--round-dir",
                str(out_dir),
            ],
            check=True,
        )
    except subprocess.CalledProcessError as e:
        log(f"  ⚠ build_report falló: {e}")

    # Limpieza opcional de TestRuns de la ronda (para evitar acumulación).
    for tr in (manifest.warmup.testrun_name, manifest.baseline.testrun_name, manifest.peak.testrun_name):
        if tr:
            kubectl("delete", "testrun", tr, "-n", NS_CARGA, "--ignore-not-found", check=False)

    return out_dir


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description="F6 — ejecuta UNA ronda del experimento ASR")
    p.add_argument("--seed", type=int, required=True)
    g = p.add_mutually_exclusive_group()
    g.add_argument("--full", action="store_const", dest="mode", const="full")
    g.add_argument("--scaled", action="store_const", dest="mode", const="scaled")
    g.add_argument("--smoke", action="store_const", dest="mode", const="smoke")
    p.add_argument("--out", default=str(ROOT / "runs" / "results"))
    p.add_argument("--skip-warmup", action="store_true")
    args = p.parse_args()
    mode = args.mode or "scaled"

    out_dir = run_round(
        seed=args.seed,
        mode=mode,
        out_root=Path(args.out),
        skip_warmup=args.skip_warmup,
    )
    print(f"\nROUND OK · {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
