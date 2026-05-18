#!/usr/bin/env python3
"""Orquestador de la prueba de capacidad (stress) — 10 min, ramping 10→100 r/s.

Procedimiento:
    1. Bundlea stress_100rps.js con bundle_k6.py.
    2. Crea/actualiza ConfigMap k6-stress-script en namespace carga.
    3. Aplica el TestRun k6-stress con nombre único (timestamp + seed).
    4. Espera a que el TestRun llegue a Finished/Stopped.
    5. Snapshot de métricas de Prometheus (k6 + server-side CDT).
    6. Genera stress_report.html auto-contenido.

Uso:
    python runs/run_stress.py [--seed 42] [--out runs/results]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from runs.lib.manifest import write_atomic_json  # noqa: E402
from runs.lib.prometheus import PrometheusClient  # noqa: E402

NS_CARGA = "carga"
STRESS_DURATION_S = 620  # 10 min + margen
STRESS_YAML = ROOT / "infra" / "k8s" / "carga" / "k6-stress.yaml"
STRESS_SCRIPT_SRC = ROOT / "load" / "scenarios" / "stress_100rps.js"
STRESS_DIST = ROOT / "load" / "dist" / "stress_100rps.bundled.js"
BUNDLE_SCRIPT = ROOT / "scripts" / "bundle_k6.py"


def log(msg: str) -> None:
    print(f"[run_stress {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def kubectl(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["kubectl", *args], check=check, capture_output=True, text=True
    )


def bundle_stress_script() -> Path:
    """Bundlea el script de stress en load/dist/."""
    STRESS_DIST.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [sys.executable, str(BUNDLE_SCRIPT), str(STRESS_SCRIPT_SRC), str(STRESS_DIST)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"bundle_k6 falló: {result.stderr}")
    log(f"Script bundleado → {STRESS_DIST}")
    return STRESS_DIST


def apply_configmap() -> None:
    bundled = bundle_stress_script()
    r = subprocess.run(
        [
            "kubectl", "create", "configmap", "k6-stress-script",
            "-n", NS_CARGA,
            f"--from-file=stress_100rps.js={bundled}",
            "--dry-run=client", "-o", "yaml",
        ],
        check=True, capture_output=True, text=True,
    )
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(r.stdout)
        tmp = Path(f.name)
    try:
        kubectl("apply", "-f", str(tmp))
        log("ConfigMap k6-stress-script aplicado")
    finally:
        tmp.unlink(missing_ok=True)


def submit_stress_testrun(seed: int, suffix: str) -> str:
    """Aplica el TestRun stress con nombre único. Devuelve el nombre final."""
    base_name = "k6-stress"
    new_name = f"{base_name}-{suffix}"
    text = STRESS_YAML.read_text()
    text = text.replace(f"name: {base_name}", f"name: {new_name}", 1)

    # Inyectar SEED
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if "name: SEED" in ln:
            for j in range(i + 1, min(i + 4, len(lines))):
                if lines[j].lstrip().startswith("value:"):
                    prefix = lines[j][: lines[j].index("value:") + len("value:")]
                    lines[j] = f'{prefix} "{seed}"'
                    break
    text = "\n".join(lines)
    # Desactivar cleanup para poder leer el status después
    text = text.replace("cleanup: post", "# cleanup: post (disabled by run_stress)")

    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(text)
        tmp = Path(f.name)
    try:
        kubectl("apply", "-f", str(tmp))
        log(f"TestRun {new_name} creado")
        return new_name
    finally:
        tmp.unlink(missing_ok=True)


def _get_job_times(job_name: str) -> tuple[float, float] | None:
    r = kubectl("get", "job", job_name, "-n", NS_CARGA, "-o", "json", check=False)
    if r.returncode != 0 or not r.stdout:
        return None
    try:
        obj = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    status = obj.get("status", {}) or {}
    if not status.get("succeeded", 0):
        return None
    start_str = status.get("startTime")
    end_str = status.get("completionTime")
    if not start_str or not end_str:
        return None
    try:
        s = datetime.strptime(start_str, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        e = datetime.strptime(end_str, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        return s, e
    except Exception:
        return None


def wait_testrun(name: str, timeout_s: int = 1800) -> tuple[float, float]:
    """Espera a que el TestRun llegue a Finished/Stopped. Devuelve (start_ts, end_ts)."""
    deadline = time.time() + timeout_s
    log(f"  esperando TestRun {name} (timeout {timeout_s}s)…")
    last_stage = None
    runner_start_ts: float | None = None

    while time.time() < deadline:
        r = kubectl("get", "testrun", name, "-n", NS_CARGA, "-o", "json", check=False)
        if r.returncode == 0 and r.stdout:
            obj = json.loads(r.stdout)
            stage = (obj.get("status", {}) or {}).get("stage", "")
            if stage != last_stage:
                log(f"    stage={stage}")
                last_stage = stage
            if stage == "started" and runner_start_ts is None:
                runner_start_ts = time.time()
            if stage in ("finished", "stopped", "error"):
                end_ts = time.time()
                start_ts = runner_start_ts or (end_ts - STRESS_DURATION_S)
                job_times = _get_job_times(f"{name}-1")
                if job_times:
                    start_ts, end_ts = job_times
                return start_ts, end_ts
        else:
            job_times = _get_job_times(f"{name}-1")
            if job_times:
                log(f"    TestRun CR borrado (cleanup:post). Job {name}-1 terminó OK")
                return job_times
        time.sleep(5)

    raise RuntimeError(f"TestRun {name} no alcanzó finished en {timeout_s}s")


STRESS_SNAPSHOT_QUERIES = {
    # Tasa de requests observada por k6
    "k6_req_rate": "rate(k6_http_reqs_total[15s])",
    # Latencia P50/P95 del lado k6 (en ms — k6 prometheus_rw usa ms)
    "k6_p95_latency_ms": (
        "histogram_quantile(0.95, sum by (le) (rate(k6_http_req_duration_bucket[1m])))"
    ),
    "k6_p50_latency_ms": (
        "histogram_quantile(0.50, sum by (le) (rate(k6_http_req_duration_bucket[1m])))"
    ),
    # VUs activos
    "k6_vus": "k6_vus",
    # Errores acumulados (Counter custom del script)
    "k6_error_total": "sum(k6_cdt_error_total)",
    "k6_success_total": "sum(k6_cdt_success_total)",
    # Latencia server-side (en segundos — métrica Spring Boot via Micrometer)
    "cdt_p95_server_s": (
        "histogram_quantile(0.95, sum by (le) "
        "(rate(cdt_open_handler_duration_seconds_bucket"
        '{exported_endpoint="open_cdt"}[1m])))'
    ),
    "cdt_p50_server_s": (
        "histogram_quantile(0.50, sum by (le) "
        "(rate(cdt_open_handler_duration_seconds_bucket"
        '{exported_endpoint="open_cdt"}[1m])))'
    ),
}


def snapshot_stress(prom: PrometheusClient, start: float, end: float, out_dir: Path) -> dict:
    bundle: dict = {"start": start, "end": end, "queries": {}}
    for k, q in STRESS_SNAPSHOT_QUERIES.items():
        try:
            bundle["queries"][k] = {
                "promql": q,
                "result": prom.query_range(q, start, end, step_s=10),
            }
        except Exception as e:
            bundle["queries"][k] = {"promql": q, "error": str(e)}
    write_atomic_json(out_dir / "stress_snapshot.json", bundle)
    log(f"Snapshot guardado ({len(bundle['queries'])} queries)")
    return bundle


def compute_summary(prom: PrometheusClient, snapshot: dict, start: float, end: float) -> dict:
    summary: dict = {"start_ts": start, "end_ts": end, "duration_s": end - start}

    # Peak y promedio de req/s desde el snapshot
    req_rate_block = snapshot.get("queries", {}).get("k6_req_rate", {})
    all_rps = []
    for series in req_rate_block.get("result", []) or []:
        for _, v in series.get("values", []):
            try:
                val = float(v)
                if val == val:  # not NaN
                    all_rps.append(val)
            except (ValueError, TypeError):
                pass
    if all_rps:
        summary["peak_rps"] = max(all_rps)
        summary["avg_rps"] = sum(all_rps) / len(all_rps)
    else:
        summary["peak_rps"] = None
        summary["avg_rps"] = None

    # P95 durante el periodo sostenido (3min-8min = t+180 a t+480)
    sustained_start = start + 180
    sustained_end = start + 480
    p95_block = snapshot.get("queries", {}).get("k6_p95_latency_ms", {})
    p95_vals = []
    for series in p95_block.get("result", []) or []:
        for ts, v in series.get("values", []):
            try:
                ts_f = float(ts)
                if sustained_start <= ts_f <= sustained_end:
                    val = float(v)
                    if val == val:
                        p95_vals.append(val)
            except (ValueError, TypeError):
                pass
    summary["p95_ms_sustained"] = (sum(p95_vals) / len(p95_vals)) if p95_vals else None

    # Totales de requests (instant query al final del test)
    try:
        err_r = prom.query("sum(k6_cdt_error_total)", when=end)
        ok_r = prom.query("sum(k6_cdt_success_total)", when=end)
        err_count = float(err_r[0]["value"][1]) if err_r else 0.0
        ok_count = float(ok_r[0]["value"][1]) if ok_r else 0.0
        total = err_count + ok_count
        summary["total_requests"] = total
        summary["error_count"] = err_count
        summary["error_rate_pct"] = (err_count / total * 100) if total > 0 else 0.0
    except Exception as e:
        summary["total_requests"] = None
        summary["error_rate_pct"] = None
        summary["error_summary_error"] = str(e)

    return summary


def run_stress(seed: int, out_root: Path) -> Path:
    # Limpieza previa de TestRuns y Jobs huérfanos
    kubectl("delete", "testrun", "--all", "-n", NS_CARGA, "--ignore-not-found", check=False)
    kubectl("delete", "job", "--all", "-n", NS_CARGA, "--ignore-not-found", check=False)
    time.sleep(2)

    run_id = f"stress-{int(time.time())}-s{seed}"
    out_dir = out_root / run_id
    out_dir.mkdir(parents=True, exist_ok=True)
    log(f"Directorio de resultados: {out_dir}")

    apply_configmap()

    suffix = f"s{seed}-{int(time.time())}"
    tr_name = submit_stress_testrun(seed, suffix)

    start_ts, end_ts = wait_testrun(tr_name, timeout_s=STRESS_DURATION_S * 2 + 120)
    log(f"Stress test completado: duración {end_ts - start_ts:.0f}s")

    prom = PrometheusClient()
    snapshot = snapshot_stress(prom, start_ts, end_ts, out_dir)

    summary = compute_summary(prom, snapshot, start_ts, end_ts)
    write_atomic_json(out_dir / "stress_summary.json", summary)

    peak_rps = summary.get("peak_rps")
    p95 = summary.get("p95_ms_sustained")
    err_pct = summary.get("error_rate_pct")
    log(
        f"Resumen: peak={peak_rps:.1f} r/s, P95={p95:.0f} ms, error={err_pct:.2f}%"
        if (peak_rps and p95 and err_pct is not None) else "Resumen: datos parciales"
    )

    # Reporte HTML
    log("generando stress_report.html …")
    try:
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "report" / "build_stress_report.py"),
                "--stress-dir", str(out_dir),
            ],
            check=True,
        )
    except subprocess.CalledProcessError as e:
        log(f"  build_stress_report falló (stdout: {e.stdout}, stderr: {e.stderr})")

    # Limpieza del TestRun
    kubectl("delete", "testrun", tr_name, "-n", NS_CARGA, "--ignore-not-found", check=False)

    return out_dir


def main() -> int:
    p = argparse.ArgumentParser(description="Stress test de capacidad — 10 min, hasta 100 r/s")
    p.add_argument("--seed", type=int, default=42, help="Seed aleatorio (default: 42)")
    p.add_argument("--out", default=str(ROOT / "runs" / "results"), help="Directorio de salida")
    args = p.parse_args()

    out_dir = run_stress(seed=args.seed, out_root=Path(args.out))
    report = out_dir / "stress_report.html"
    print(f"\nSTRESS OK · {report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
