"""Cliente HTTP minimalista para la API de Prometheus.

Usado por todos los evaluadores AC-* y por el snapshot de métricas que se
serializa por ronda. La API se accede vía `kubectl exec` al pod del Prometheus
operator dentro de `observabilidad`, o vía URL directa si la variable
`PROM_URL` está definida (port-forward del operador).

Diseño:
    * Sin dependencia de `kubernetes` python client — usamos `kubectl exec`
      por simplicidad. Esto evita dependencias extras y funciona dentro del
      kubeconfig actual del usuario (consistente con tests/f*/run-gates.sh).
    * Range queries con `step` configurable.
    * Tolerancia a fallas: cada query devuelve un dict con `status` propio.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from typing import Any, Iterable
from urllib.parse import quote

import requests


@dataclass
class PromConfig:
    """Configuración del acceso a Prometheus.

    Si `url` está definido (env `PROM_URL`), se usa HTTP directo; si no, se
    usa `kubectl exec` al pod en `observabilidad`.
    """

    url: str | None = None
    pod_namespace: str = "observabilidad"
    pod_label: str = "app.kubernetes.io/name=prometheus"
    pod_container: str = "prometheus"
    timeout_s: int = 30

    @classmethod
    def from_env(cls) -> "PromConfig":
        return cls(url=os.environ.get("PROM_URL"))


class PrometheusClient:
    """Cliente para `instant` y `range` queries de Prometheus."""

    def __init__(self, cfg: PromConfig | None = None):
        self.cfg = cfg or PromConfig.from_env()
        self._kubectl = shutil.which("kubectl")
        self._pod: str | None = None

    # ------------------------------------------------------------------
    # Backend resolution
    # ------------------------------------------------------------------
    def _resolve_pod(self) -> str:
        if self._pod:
            return self._pod
        if not self._kubectl:
            raise RuntimeError("kubectl no está en PATH y no hay PROM_URL")
        out = subprocess.run(
            [
                self._kubectl,
                "get",
                "pod",
                "-n",
                self.cfg.pod_namespace,
                "-l",
                self.cfg.pod_label,
                "-o",
                "jsonpath={.items[0].metadata.name}",
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if not out:
            raise RuntimeError(
                f"No se encontró pod Prometheus en namespace {self.cfg.pod_namespace}"
            )
        self._pod = out
        return out

    def _http_get(self, path: str, params: dict[str, str]) -> dict:
        """Ejecuta GET via requests (PROM_URL) o kubectl exec wget."""
        if self.cfg.url:
            r = requests.get(
                f"{self.cfg.url.rstrip('/')}{path}",
                params=params,
                timeout=self.cfg.timeout_s,
            )
            r.raise_for_status()
            return r.json()

        pod = self._resolve_pod()
        qs = "&".join(f"{k}={quote(str(v), safe='')}" for k, v in params.items())
        url = f"http://localhost:9090{path}?{qs}"
        cmd = [
            self._kubectl,
            "exec",
            "-n",
            self.cfg.pod_namespace,
            pod,
            "-c",
            self.cfg.pod_container,
            "--",
            "wget",
            "-qO-",
            url,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=self.cfg.timeout_s + 10)
        if proc.returncode != 0:
            raise RuntimeError(f"kubectl exec falló: {proc.stderr[:300]}")
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as e:
            raise RuntimeError(f"Respuesta no-JSON de Prometheus: {proc.stdout[:300]}") from e

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    def query(self, promql: str, when: float | None = None) -> list[dict]:
        """Instant query. Devuelve la lista `data.result` o []."""
        params = {"query": promql}
        if when is not None:
            params["time"] = str(when)
        body = self._http_get("/api/v1/query", params)
        if body.get("status") != "success":
            raise RuntimeError(f"Prometheus error: {body}")
        return body["data"]["result"]

    def query_range(
        self,
        promql: str,
        start: float,
        end: float,
        step_s: int = 15,
    ) -> list[dict]:
        """Range query. Devuelve la lista `data.result` o []."""
        params = {
            "query": promql,
            "start": str(start),
            "end": str(end),
            "step": f"{step_s}s",
        }
        body = self._http_get("/api/v1/query_range", params)
        if body.get("status") != "success":
            raise RuntimeError(f"Prometheus error: {body}")
        return body["data"]["result"]

    def first_value(self, promql: str, when: float | None = None) -> float | None:
        """Comodidad: primer valor escalar o None si vacío."""
        result = self.query(promql, when=when)
        if not result:
            return None
        try:
            return float(result[0]["value"][1])
        except (KeyError, IndexError, ValueError):
            return None

    def label_values(self, label: str) -> list[str]:
        body = self._http_get(f"/api/v1/label/{label}/values", {})
        return body.get("data", []) or []

    def has_metric(self, name: str) -> bool:
        return name in self.label_values("__name__")


def utility_iter_minutes(start: float, end: float) -> Iterable[tuple[float, float]]:
    """Genera ventanas de 1 minuto [t, t+60) en el intervalo dado."""
    t = start
    while t < end:
        nxt = min(t + 60, end)
        yield t, nxt
        t = nxt


def percentile_from_buckets(
    buckets: dict[str, float],
    quantile: float,
) -> float | None:
    """Calcula `histogram_quantile` clásico sobre un dict {le: cumulative_count}.

    Usado cuando se trabaja con un snapshot en JSON (no PromQL en vivo).
    Equivalente a la implementación de Prometheus.
    """
    if not buckets or quantile < 0 or quantile > 1:
        return None
    items = []
    for le, count in buckets.items():
        if le == "+Inf":
            items.append((float("inf"), float(count)))
        else:
            try:
                items.append((float(le), float(count)))
            except ValueError:
                continue
    items.sort(key=lambda x: x[0])
    if not items:
        return None
    total = items[-1][1]
    if total <= 0:
        return None
    target = quantile * total
    prev_le, prev_count = 0.0, 0.0
    for le, count in items:
        if count >= target:
            if le == float("inf"):
                return prev_le if prev_le > 0 else None
            if count == prev_count:
                return prev_le
            # interpolación lineal Prometheus-style
            frac = (target - prev_count) / (count - prev_count)
            return prev_le + frac * (le - prev_le)
        prev_le, prev_count = le, count
    return items[-1][0] if items[-1][0] != float("inf") else None
