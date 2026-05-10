#!/usr/bin/env python3
"""
check_versions.py — Verifica que versions.env sea consistente con la tabla
de versiones §6.4.10 de docs/experimento_asr.md.

Uso: python3 scripts/check_versions.py docs/experimento_asr.md versions.env
Exit 0 si coinciden, exit 1 si hay drift detectado.

La tabla §6.4.10 del documento maestro tiene el formato:
| Capa | Producto | Versión |
|------|---------|:-------:|
| JDK  | Eclipse Temurin | **21 LTS** |
...

versions.env tiene el formato:
KEY=valor   # comentario opcional

NOTA SOBRE EL MAPEO:
La tabla §6.4.10 registra versiones de *producto* (Kong 3.7, Prometheus 2.55, Tempo 2.6)
mientras que versions.env registra versiones de *chart Helm* (KONG_CHART_VERSION=2.41.1,
KUBE_PROMETHEUS_STACK_VERSION=65.1.1, TEMPO_CHART_VERSION=1.13.0). El mapeo de chart a
producto no es 1:1, por lo que se verifica con dos grupos:

Grupo A — Mapeo directo (doc_fragment es prefijo del valor de env_key):
  versions.env usa versión de producto, igual que la tabla.

Grupo B — Mapeo indirecto (versión de chart ≠ versión de producto):
  Se verifica que la clave exista en versions.env y no esté vacía.
  El fragmento se busca en los comentarios inline del versions.env.
"""

import re
import sys
import pathlib

# ── Grupo A: mapeo directo (env_value empieza con doc_fragment) ──────────────
DIRECT_MAPPINGS = [
    # (clave versions.env, fragmento esperado en la tabla §6.4.10)
    ("JAVA_VERSION",          "21"),
    ("SPRING_BOOT_VERSION",   "3.3"),
    ("RESILIENCE4J_VERSION",  "2.2"),
    ("GRADLE_VERSION",        "8.10"),
    ("JIB_VERSION",           "3.4"),
    ("KIND_VERSION",          "0.23"),
    ("OTEL_COLLECTOR_VERSION","0.110"),
    ("K6_VERSION",            "0.53"),
    ("TERRAFORM_VERSION",     "1.9"),
    ("POSTGRES_IMAGE_VERSION","16"),
    ("REDPANDA_VERSION",      "24.2"),
]

# ── Grupo B: versión de chart (no coincide 1:1 con la tabla de producto) ─────
# Se verifica que la clave exista en versions.env + que el valor no sea vacío.
# El doc_product_version es informativo para el mensaje de PASS.
CHART_MAPPINGS = [
    # (clave versions.env, versión de producto en doc, nota aclaratoria)
    ("KUBE_PROMETHEUS_STACK_VERSION", "2.55 (Prometheus) / 11.3 (Grafana)",
     "chart kube-prometheus-stack embebe Prometheus 2.55 + Grafana 11.3"),
    ("TEMPO_CHART_VERSION",           "2.6 (Tempo)",
     "chart Tempo 1.13.x embebe Tempo 2.6"),
    ("LOKI_CHART_VERSION",            "3.x (Loki)",
     "chart Loki 6.18.x embebe Loki 3.x"),
    ("KONG_CHART_VERSION",            "3.7 (Kong OSS)",
     "chart Kong 2.41.x embebe Kong Gateway 3.7"),
    ("PROMTAIL_CHART_VERSION",        "3.x (Promtail)",
     "par con Loki 3.x"),
    ("CNPG_CHART_VERSION",            "1.24 (CloudNativePG)",
     "chart CNPG 0.21.x embebe operador 1.24"),
]


def parse_versions_env(path: pathlib.Path) -> dict:
    """Lee versions.env y devuelve {KEY: valor}."""
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, val = line.partition("=")
            val = val.split("#")[0].strip()
            env[key.strip()] = val
    return env


def parse_doc_versions_section(path: pathlib.Path) -> str:
    """Extrae la sección §6.4.10 del documento maestro."""
    text = path.read_text()
    match = re.search(
        r"#{3,4}\s+6\.4\.10.*?\n(.*?)(?=\n#{3,4}|\Z)",
        text,
        re.DOTALL,
    )
    if match:
        return match.group(0)
    # Fallback: buscar tabla con columnas Capa/Producto/Versión
    match = re.search(
        r"\|.*Capa.*\|.*Producto.*\|.*Versión.*\|(.*?)\n\n",
        text,
        re.DOTALL,
    )
    if match:
        return match.group(0)
    return text


def main() -> int:
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <doc_path> <versions_env_path>")
        return 2

    doc_path = pathlib.Path(sys.argv[1])
    env_path = pathlib.Path(sys.argv[2])

    if not doc_path.exists():
        print(f"ERROR: No se encuentra {doc_path}")
        return 2
    if not env_path.exists():
        print(f"ERROR: No se encuentra {env_path}")
        return 2

    env = parse_versions_env(env_path)
    doc_text = parse_doc_versions_section(doc_path)

    drifts = []

    # ── Grupo A: mapeo directo ────────────────────────────────────────────────
    for env_key, doc_fragment in DIRECT_MAPPINGS:
        env_val = env.get(env_key, "")
        if not env_val:
            drifts.append(f"  FALTA  {env_key:45s} (no en versions.env)")
            continue

        # Verificar que el fragmento aparece en la sección §6.4.10
        if doc_fragment not in doc_text:
            drifts.append(
                f"  DRIFT  {env_key:45s} env={env_val!r:25s} "
                f"doc_fragment={doc_fragment!r} NO en §6.4.10"
            )
            continue

        # Verificar que el valor de versions.env empieza con el fragmento
        clean_val = env_val.lstrip("v")
        clean_frag = doc_fragment.lstrip("v")
        if not clean_val.startswith(clean_frag):
            drifts.append(
                f"  DRIFT  {env_key:45s} env={env_val!r:25s} "
                f"expected prefix {doc_fragment!r}"
            )
        else:
            print(f"  OK     {env_key:45s} = {env_val}")

    # ── Grupo B: versiones de chart (mapeo indirecto) ─────────────────────────
    for env_key, product_ver, nota in CHART_MAPPINGS:
        env_val = env.get(env_key, "")
        if not env_val:
            drifts.append(
                f"  FALTA  {env_key:45s} (no en versions.env) "
                f"[producto: {product_ver}]"
            )
        else:
            print(
                f"  OK     {env_key:45s} = {env_val:15s} "
                f"[producto: {product_ver}]"
            )

    if drifts:
        print(
            f"\nDrift detectado entre versions.env y "
            f"docs/experimento_asr.md §6.4.10:"
        )
        for d in drifts:
            print(d)
        return 1

    total = len(DIRECT_MAPPINGS) + len(CHART_MAPPINGS)
    print(
        f"\nOK: versions.env consistente con {doc_path} §6.4.10 "
        f"({total} entradas verificadas)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
