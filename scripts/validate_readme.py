#!/usr/bin/env python3
"""F8 — Validador del README.md.

Verifica que el README cumple los requisitos del spec §8.3 y §8.4:
  1. Las 10 secciones obligatorias (## 1..10) existen.
  2. §6 tiene un comando para cada uno de los 6 componentes del §3.1.
  3. §4 cita 'make up', 'make experiment', 'make report'.
  4. Las versiones citadas en el README coinciden con versions.env.
  5. Los enlaces internos (docs/, diagramas_final/, .claude/specs/, .claude/agents/)
     resuelven a paths existentes.
  6. §8 tiene >= 6 subsecciones (###).

Uso:
    python3 scripts/validate_readme.py
    python3 scripts/validate_readme.py --check-component-coverage  # solo §6
    python3 scripts/validate_readme.py --readme README.md --versions versions.env

Exit 0 si todo pasa; exit 1 con mensaje descriptivo si algo falla.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------
# Componentes obligatorios del subset mínimo viable §3.1
# Nombres exactos del modelo del equipo (CLAUDE.md §Vista estructural).
# ---------------------------------------------------------------------------
REQUIRED_COMPONENTS = [
    "ApiGateway",
    "CDTXPais",
    "AlmacenCDTXPais",
    "MessageBroker",
    "ACL",
    "CoreBancoZ",
]

# ---------------------------------------------------------------------------
# Secciones obligatorias §8.3
# ---------------------------------------------------------------------------
REQUIRED_SECTIONS = [
    "## 1.",
    "## 2.",
    "## 3.",
    "## 4.",
    "## 5.",
    "## 6.",
    "## 7.",
    "## 8.",
    "## 9.",
    "## 10.",
]

# ---------------------------------------------------------------------------
# Comandos obligatorios en §4 (Inicio rápido)
# ---------------------------------------------------------------------------
REQUIRED_QUICK_COMMANDS = [
    "make up",
    "make experiment",
    "make report",
]

# ---------------------------------------------------------------------------
# Versiones a verificar contra versions.env.
# Mapa: clave en versions.env → regex para buscar en README.
# ---------------------------------------------------------------------------
VERSION_CHECKS = {
    # Los patrones aceptan tanto inline (kind v0.23) como en tabla Markdown (kind | v0.23)
    "KIND_VERSION":           r"kind[\s|]+v0\.23",
    "KUBECTL_VERSION":        r"kubectl[\s|]+v1\.30",
    "HELM_VERSION":           r"[Hh]elm[\s|]+v3\.15",
    "JAVA_VERSION":           r"(?:JDK|Java)[\s|]+21",
    "SPRING_BOOT_VERSION":    r"Spring Boot[\s|]+3\.3",
    "K6_VERSION":             r"k6[\s|]+v0\.53",
    "TERRAFORM_VERSION":      r"[Tt]erraform[\s|]+1\.9",
}

# ---------------------------------------------------------------------------
# Prefijos de paths internos que deben existir (se buscan en el README)
# ---------------------------------------------------------------------------
INTERNAL_PATH_PREFIXES = [
    "docs/",
    "diagramas_final/",
    ".claude/specs/",
    ".claude/agents/",
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_versions(path: Path) -> dict[str, str]:
    """Carga versions.env como dict key→value (ignora comentarios y vacías)."""
    versions: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            k, _, v = line.partition("=")
            versions[k.strip()] = v.strip().split("#")[0].strip()
    return versions


def section_content(lines: list[str], section_prefix: str) -> str:
    """Devuelve todo el texto desde la primera línea que empiece con section_prefix
    hasta la siguiente línea que empiece con '## '."""
    in_section = False
    out_lines = []
    for ln in lines:
        if ln.startswith(section_prefix):
            in_section = True
            out_lines.append(ln)
            continue
        if in_section:
            if ln.startswith("## ") and not ln.startswith(section_prefix):
                break
            out_lines.append(ln)
    return "\n".join(out_lines)


# ---------------------------------------------------------------------------
# Checks individuales
# ---------------------------------------------------------------------------

def check_sections(lines: list[str]) -> list[str]:
    """Verifica que las 10 secciones obligatorias existen."""
    errors = []
    text = "\n".join(lines)
    for sec in REQUIRED_SECTIONS:
        if sec not in text:
            errors.append(f"Sección '{sec}' no encontrada en README.md")
    return errors


def check_component_coverage(lines: list[str]) -> list[str]:
    """Verifica que §6 tiene un comando para cada componente del §3.1."""
    errors = []
    sec6 = section_content(lines, "## 6.")
    if not sec6:
        return ["§6 (Pruebas manuales por componente) no encontrada"]
    for comp in REQUIRED_COMPONENTS:
        if comp not in sec6:
            errors.append(
                f"§6: componente '{comp}' (§3.1) no documentado en la sección de pruebas manuales"
            )
    return errors


def check_quick_start(lines: list[str]) -> list[str]:
    """Verifica que §4 cita los 3 comandos obligatorios."""
    errors = []
    sec4 = section_content(lines, "## 4.")
    if not sec4:
        return ["§4 (Inicio rápido) no encontrada"]
    for cmd in REQUIRED_QUICK_COMMANDS:
        if cmd not in sec4:
            errors.append(f"§4: comando '{cmd}' no documentado en Inicio rápido")
    return errors


def check_versions(lines: list[str], versions_path: Path) -> list[str]:
    """Verifica que las versiones citadas en el README coinciden con versions.env."""
    errors = []
    if not versions_path.exists():
        return [f"versions.env no encontrado: {versions_path}"]
    versions = load_versions(versions_path)
    text = "\n".join(lines)
    for key, pattern in VERSION_CHECKS.items():
        env_val = versions.get(key)
        if not env_val:
            continue  # clave no existe en versions.env, no es error del README
        if not re.search(pattern, text, re.IGNORECASE):
            errors.append(
                f"Versión de '{key}' ({env_val}) no encontrada en README.md "
                f"(patrón esperado: '{pattern}')"
            )
    return errors


def check_internal_links(readme_path: Path, text: str | None = None) -> list[str]:
    """Verifica que los paths internos citados en el README existen en el repo."""
    errors = []
    if text is None:
        text = readme_path.read_text()
    root = readme_path.parent

    # Buscar paths en: `path/to/file`, [texto](path), y menciones directas
    # de prefijos INTERNAL_PATH_PREFIXES seguidas de un path relativo.
    found_paths: set[str] = set()

    # 1. Markdown links: [texto](path)
    for m in re.finditer(r'\[([^\]]+)\]\(([^)]+)\)', text):
        href = m.group(2)
        if not href.startswith("http") and not href.startswith("#"):
            found_paths.add(href)

    # 2. Backtick paths que empiecen con prefijos conocidos
    for m in re.finditer(r'`([^`]+)`', text):
        val = m.group(1)
        for prefix in INTERNAL_PATH_PREFIXES:
            if val.startswith(prefix):
                found_paths.add(val)
                break

    for p in sorted(found_paths):
        # Limpiar fragmentos (#section) y query strings
        clean = p.split("#")[0].split("?")[0]
        if not clean:
            continue
        target = root / clean
        if not target.exists():
            errors.append(f"Enlace interno no resuelve: '{p}' → {target}")

    return errors


def check_troubleshooting(lines: list[str]) -> list[str]:
    """Verifica que §8 tiene >= 6 subsecciones (###)."""
    sec8 = section_content(lines, "## 8.")
    if not sec8:
        return ["§8 (Solución de problemas) no encontrada"]
    subsections = [ln for ln in sec8.splitlines() if ln.startswith("### ")]
    if len(subsections) < 6:
        return [
            f"§8: solo {len(subsections)} escenarios de troubleshooting (mínimo 6). "
            f"Encontrados: {[s.strip() for s in subsections]}"
        ]
    return []


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="F8 — Validador del README.md (spec §8.4)"
    )
    parser.add_argument(
        "--readme",
        default=str(ROOT / "README.md"),
        help="Ruta al README.md (default: README.md en raíz del repo)",
    )
    parser.add_argument(
        "--versions",
        default=str(ROOT / "versions.env"),
        help="Ruta a versions.env (default: versions.env en raíz del repo)",
    )
    parser.add_argument(
        "--check-component-coverage",
        action="store_true",
        help="Solo verificar cobertura de componentes §3.1 en §6 (T-7 del gate F8)",
    )
    args = parser.parse_args()

    readme_path = Path(args.readme)
    versions_path = Path(args.versions)

    if not readme_path.exists():
        print(f"ERROR: README.md no encontrado: {readme_path}", file=sys.stderr)
        return 1

    text = readme_path.read_text()
    lines = text.splitlines()
    all_errors: list[str] = []

    if args.check_component_coverage:
        # Modo T-7: solo cobertura de componentes
        errors = check_component_coverage(lines)
        if errors:
            for e in errors:
                print(f"FAIL: {e}")
            return 1
        print(f"PASS: §6 cubre los {len(REQUIRED_COMPONENTS)} componentes del §3.1: "
              f"{', '.join(REQUIRED_COMPONENTS)}")
        return 0

    # Modo completo
    print(f"Validando {readme_path} ...")
    print()

    # T-4: línea count (informativo)
    line_count = len(lines)
    if line_count < 200:
        all_errors.append(f"README.md tiene {line_count} líneas (mínimo 200)")
    else:
        print(f"  OK  {line_count} líneas (>= 200)")

    # T-6: secciones
    sec_errors = check_sections(lines)
    if sec_errors:
        all_errors.extend(sec_errors)
    else:
        sec_count = sum(1 for ln in lines if re.match(r'^## \d+\.', ln))
        print(f"  OK  {sec_count} secciones numeradas (>= 10)")

    # T-7: cobertura de componentes
    comp_errors = check_component_coverage(lines)
    if comp_errors:
        all_errors.extend(comp_errors)
    else:
        print(f"  OK  §6 cubre los {len(REQUIRED_COMPONENTS)} componentes del §3.1")

    # Inicio rápido
    qs_errors = check_quick_start(lines)
    if qs_errors:
        all_errors.extend(qs_errors)
    else:
        print(f"  OK  §4 documenta los 3 comandos obligatorios")

    # T-10: versiones
    ver_errors = check_versions(lines, versions_path)
    if ver_errors:
        all_errors.extend(ver_errors)
    else:
        print(f"  OK  versiones del README coinciden con versions.env")

    # T-11: enlaces internos (reutiliza el texto ya cargado)
    link_errors = check_internal_links(readme_path, text)
    if link_errors:
        all_errors.extend(link_errors)
    else:
        print(f"  OK  enlaces internos resuelven a paths existentes")

    # T-8: troubleshooting
    ts_errors = check_troubleshooting(lines)
    if ts_errors:
        all_errors.extend(ts_errors)
    else:
        sec8 = section_content(lines, "## 8.")
        sub_count = len([ln for ln in sec8.splitlines() if ln.startswith("### ")])
        print(f"  OK  §8 tiene {sub_count} escenarios de troubleshooting (>= 6)")

    print()
    if all_errors:
        print(f"FALLOS ({len(all_errors)}):")
        for e in all_errors:
            print(f"  FAIL: {e}")
        return 1

    print("PASS: README.md cumple todos los requisitos del spec §8.3/§8.4")
    return 0


if __name__ == "__main__":
    sys.exit(main())
