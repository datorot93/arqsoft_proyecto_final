#!/usr/bin/env python3
"""F8 — Verificador de enlaces internos del README.md.

Verifica que todos los paths relativos citados en README.md
(en backticks o como [texto](path)) existan en el repositorio.

Uso:
    python3 scripts/check_links.py README.md
    python3 scripts/check_links.py README.md --verbose

Exit 0 si todos los paths resuelven; exit 1 si alguno no existe.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def extract_paths(text: str) -> list[tuple[str, str]]:
    """Extrae pares (path, contexto) del texto Markdown.

    Fuentes:
    1. Markdown links: [texto](path)  — excluye URLs http(s) y anchors (#)
    2. Backtick paths que contienen '/' y NO contienen espacios
       (para distinguir paths de comandos como `make up`)
    """
    found: list[tuple[str, str]] = []
    seen: set[str] = set()

    # 1. Markdown links
    for m in re.finditer(r'\[([^\]]*)\]\(([^)]+)\)', text):
        href = m.group(2).strip()
        if href.startswith("http") or href.startswith("#") or not href:
            continue
        # Limpiar fragmento
        clean = href.split("#")[0].split("?")[0].strip()
        if clean and clean not in seen:
            seen.add(clean)
            context = f"[{m.group(1)}]({href})"
            found.append((clean, context))

    # 2. Backtick con separador /
    for m in re.finditer(r'`([^`]+)`', text):
        val = m.group(1).strip()
        # Debe contener '/' y no tener espacios (es un path, no un comando)
        if "/" not in val or " " in val:
            continue
        # Excluir URLs
        if val.startswith("http"):
            continue
        # Excluir fragmentos que parezcan paths de sistema absolutos de otros SO
        if val.startswith("/etc/") or val.startswith("/usr/") or val.startswith("/var/"):
            continue
        # Excluir wsl-config
        if "wslconfig" in val.lower():
            continue
        # Solo paths que empiecen con prefijos conocidos del repo
        known_prefixes = (
            "docs/", "diagramas_final/", ".claude/", "infra/", "scripts/",
            "services/", "load/", "runs/", "report/", "tests/",
        )
        if not any(val.startswith(p) for p in known_prefixes):
            continue
        clean = val.split("#")[0].strip()
        if clean and clean not in seen:
            seen.add(clean)
            found.append((clean, f"`{val}`"))

    return found


def check_paths(readme_path: Path, verbose: bool = False) -> int:
    """Verifica que todos los paths extraídos existan. Retorna número de fallos."""
    root = readme_path.parent
    text = readme_path.read_text()
    paths = extract_paths(text)

    if verbose:
        print(f"Paths encontrados en {readme_path}: {len(paths)}")

    failures = []
    for p, ctx in paths:
        target = root / p
        if target.exists():
            if verbose:
                print(f"  OK  {p}")
        else:
            failures.append((p, ctx))

    if failures:
        print(f"FAIL: {len(failures)} path(s) no resuelven en {readme_path}:")
        for p, ctx in failures:
            print(f"  FAIL: '{p}'  (mencionado como: {ctx})")
        return len(failures)

    print(f"PASS: todos los {len(paths)} paths internos resuelven (README.md)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="F8 — Verificador de enlaces internos del README.md"
    )
    parser.add_argument(
        "readme",
        nargs="?",
        default=str(Path(__file__).resolve().parents[1] / "README.md"),
        help="Ruta al README.md (default: README.md en raíz del repo)",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Mostrar todos los paths encontrados y su estado",
    )
    args = parser.parse_args()

    readme_path = Path(args.readme)
    if not readme_path.exists():
        print(f"ERROR: {readme_path} no encontrado", file=sys.stderr)
        return 1

    failures = check_paths(readme_path, verbose=args.verbose)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
