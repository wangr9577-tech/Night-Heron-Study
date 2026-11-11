"""Independent previews: prefer LibreOffice's PPTX rendering; use the bundled renderer as fallback."""

import argparse
import json
import os
import subprocess
from pathlib import Path
from uuid import uuid4

import pymupdf
from PIL import Image


def render(source: Path, directory: Path, report: Path | None = None):
    source, directory = source.resolve(), directory.resolve()
    root = Path(__file__).resolve().parents[1]
    soffice = os.getenv("ZHUOZHI_SOFFICE")
    local = root / ".tools/LibreOffice/program/soffice.com"
    if not soffice and local.is_file():
        soffice = str(local)
    directory.mkdir(parents=True, exist_ok=True)
    if soffice:
        work = root / "tmp" / ("ppt-preview-" + uuid4().hex)
        work.mkdir(parents=True, exist_ok=True)
        process = subprocess.run(
            [
                soffice,
                "-env:UserInstallation=" + (work / "profile").as_uri(),
                "--headless",
                "--convert-to",
                "pdf",
                "--outdir",
                str(work),
                str(source),
            ],
            check=True,
            capture_output=True,
            timeout=90,
        )
        with pymupdf.open(work / (source.stem + ".pdf")) as pdf:
            count = len(pdf)
            for index, page in enumerate(pdf):
                page.get_pixmap(matrix=pymupdf.Matrix(1.25, 1.25)).save(directory / f"slide-{index + 1}.png")
        method = "LibreOffice to PDF; PyMuPDF to PNG"
    else:
        process = subprocess.run(
            [
                os.getenv("ZHUOZHI_NODE", "node"),
                str(root / "scripts/render_pptx.mjs"),
                str(source),
                str(directory),
            ],
            capture_output=True,
            timeout=90,
        )
        lines = process.stdout.decode("utf-8", errors="replace").strip().splitlines()
        manifest = json.loads(lines[-1]) if lines else {}
        assert manifest.get("slideCount", 0) > 0, process.stderr.decode(errors="replace")
        count = manifest["slideCount"]
        method = "artifact-tool fallback (all PNGs independently verified)"
    for index in range(count):
        with Image.open(directory / f"slide-{index + 1}.png") as image:
            image.verify()
    for image in directory.glob("slide-*.png"):
        if image.stem[6:].isdecimal() and int(image.stem[6:]) > count:
            image.unlink()
    result = dict(
        slide_count=count, renderer=method, renderer_exit_code=process.returncode, all_images_verified=True
    )
    if report:
        report.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    print(json.dumps(render(args.source, args.output, args.report), ensure_ascii=False))
