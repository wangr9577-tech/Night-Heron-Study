"""Build a source + contracts + verified examples archive; exclude environments and private data."""

import hashlib
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


def main():
    root = Path(__file__).resolve().parents[1]
    output = root / "output/啄知AI_B1-B8_交付包.zip"
    roots = [
        "backend",
        "contracts",
        "docs",
        "examples",
        "scripts",
        "tests",
        "output/demo",
        "output/verification",
    ]
    paths = [root / name for name in ["README.md", "pyproject.toml", "uv.lock", ".env.example", ".gitignore"]]
    for directory in roots:
        paths.extend(
            p
            for p in (root / directory).rglob("*")
            if p.is_file()
            and "__pycache__" not in p.parts
            and "office-render" not in p.parts
            and "pdf-previews" not in p.parts
            and not p.name.endswith(".inspect.ndjson")
            and p.name not in {"package-report.json", "pptx-validation.json"}
        )
    paths = sorted(set(paths))
    manifest = {
        p.relative_to(root).as_posix(): {
            "sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
            "bytes": p.stat().st_size,
        }
        for p in paths
    }
    with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=6) as archive:
        for path in paths:
            archive.write(path, path.relative_to(root).as_posix())
        archive.writestr("MANIFEST.sha256.json", json.dumps(manifest, ensure_ascii=False, indent=2))
    with ZipFile(output) as archive:
        assert archive.testzip() is None
        for name, entry in manifest.items():
            assert hashlib.sha256(archive.read(name)).hexdigest() == entry["sha256"], name
    report = dict(
        archive=str(output),
        files=len(manifest),
        bytes=output.stat().st_size,
        sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
        all_hashes_verified=True,
        excluded=[".venv", ".tools", "data", "tmp", ".env", "__pycache__"],
    )
    (root / "output/verification/package-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
