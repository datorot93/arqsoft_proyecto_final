"""Construcción del `manifest.json` de cada ronda.

Captura: seed, hash git, versiones del stack (de `versions.env`), timestamps
de las 3 etapas, hash del documento maestro `experimento_asr.md` (campo
`experiment_spec_sha` que F6.T-9 verifica), y duraciones efectivas.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


def _project_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _git_sha() -> str:
    try:
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=_project_root(),
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except Exception:
        return "unknown"


def _file_sha256(path: Path) -> str:
    if not path.exists():
        return "missing"
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def _read_versions_env() -> dict[str, str]:
    path = _project_root() / "versions.env"
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


@dataclass
class StagePhase:
    name: str
    started_at: float | None = None
    ended_at: float | None = None
    duration_s: float | None = None
    testrun_name: str | None = None
    notes: str = ""


@dataclass
class RoundManifest:
    """Información reproducible de una ronda."""

    round_id: str
    seed: int
    scaled: bool
    git_sha: str = field(default_factory=_git_sha)
    experiment_spec_sha: str = field(
        default_factory=lambda: _file_sha256(_project_root() / "docs" / "experimento_asr.md")
    )
    versions: dict[str, str] = field(default_factory=_read_versions_env)
    started_at: float = 0.0
    ended_at: float = 0.0
    warmup: StagePhase = field(default_factory=lambda: StagePhase(name="warmup"))
    baseline: StagePhase = field(default_factory=lambda: StagePhase(name="baseline_asr1"))
    peak: StagePhase = field(default_factory=lambda: StagePhase(name="peak_asr2"))
    config: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        return d

    def write(self, path: Path) -> None:
        path.write_text(json.dumps(self.to_dict(), indent=2, sort_keys=False))


def write_atomic_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, default=str))
    os.replace(tmp, path)
