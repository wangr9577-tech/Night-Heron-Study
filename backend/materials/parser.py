import io
import os
import re
import subprocess
import threading
import zipfile
from pathlib import Path

import numpy as np
import pymupdf
from PIL import Image, ImageOps
from pptx import Presentation

from backend.engine.errors import DomainError, require

OCR_LOCK = threading.Lock()
OCR_ENGINE = None


def ocr_image(image):
    global OCR_ENGINE
    # Avoid ONNX starting one CPU thread per core per session on large Windows machines.
    with OCR_LOCK:
        if OCR_ENGINE is None:
            try:
                from rapidocr_onnxruntime import RapidOCR

                OCR_ENGINE = RapidOCR(intra_op_num_threads=2, inter_op_num_threads=1)
            except ImportError as exc:
                raise DomainError("OCR_UNAVAILABLE", "安装 rapidocr-onnxruntime 后可重试", 503, True) from exc
        rgb = ImageOps.exif_transpose(image).convert("RGB")
        require(rgb.width * rgb.height <= 40_000_000, "IMAGE_TOO_LARGE", "图片像素过大")
        rgb.thumbnail((2200, 3000))
        result, _ = OCR_ENGINE(np.asarray(rgb))
    return [{"text": row[1], "confidence": round(float(row[2]), 4), "bbox": row[0]} for row in (result or [])]


def legacy_ppt(path, work_dir):
    soffice = os.getenv("ZHUOZHI_SOFFICE")
    local_converter = Path(__file__).parents[2] / ".tools/LibreOffice/program/soffice.com"
    if not soffice and local_converter.is_file():
        soffice = str(local_converter)
    output = work_dir / (path.stem + ".pptx")
    if soffice:
        try:
            subprocess.run(
                [
                    soffice,
                    "-env:UserInstallation=" + (work_dir / ("lo-profile-" + path.stem)).resolve().as_uri(),
                    "--headless",
                    "--convert-to",
                    "pptx",
                    "--outdir",
                    str(work_dir),
                    str(path),
                ],
                capture_output=True,
                check=True,
                timeout=90,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise DomainError("PPT_CONVERSION_FAILED", "PPT 转换失败，请检查转换器", 422, True) from exc
    elif os.name == "nt":
        script = Path(__file__).with_name("convert_ppt.ps1")
        try:
            subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-NonInteractive",
                    "-File",
                    str(script),
                    "-SourcePath",
                    str(path.resolve()),
                    "-OutputPath",
                    str(output.resolve()),
                ],
                check=True,
                capture_output=True,
                timeout=90,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise DomainError(
                "PPT_CONVERTER_UNAVAILABLE", "旧版 PPT 需要 PowerPoint 或配置 LibreOffice", 503, True
            ) from exc
    else:
        raise DomainError("PPT_CONVERTER_UNAVAILABLE", "配置 ZHUOZHI_SOFFICE 后可重试旧版 PPT", 503, True)
    require(output.is_file(), "PPT_CONVERSION_FAILED", "转换器未产生 PPTX", 422, True)
    return output


def pdf_page_content(page):
    text = page.get_text(sort=True).strip()
    native = [
        (pymupdf.Rect(b[:4]), b[4].strip()) for b in page.get_text("blocks") if b[6] == 0 and b[4].strip()
    ]
    sparse = len(re.sub(r"\s", "", text)) < 12
    regions = [page.rect] if sparse else []
    if not sparse:
        for info in page.get_image_info():
            region = pymupdf.Rect(info["bbox"]) & page.rect
            if region.is_empty or region.get_area() < page.rect.get_area() * 0.2:
                continue
            inside = [
                (rect, value)
                for rect, value in native
                if region.contains(rect.tl) and region.contains(rect.br)
            ]
            chars = sum(len(re.sub(r"\s", "", value)) for _, value in inside)
            body_chars = sum(
                len(re.sub(r"\s", "", value))
                for rect, value in inside
                if region.y0 + 0.15 * region.height
                < (rect.y0 + rect.y1) / 2
                < region.y1 - 0.15 * region.height
            )
            span = max((r.y1 for r, _ in inside), default=region.y0) - min(
                (r.y0 for r, _ in inside), default=region.y0
            )
            # A header/footer over a scanned page is not a usable text layer for its body.
            if chars < 12 or body_chars < 12 or span < region.height * 0.3:
                if not any(existing.contains(region) for existing in regions):
                    regions = [existing for existing in regions if not region.contains(existing)] + [region]
    lines, blocks = [], list(native)
    for region in regions:
        require(region.get_area() * 4 <= 40_000_000, "IMAGE_TOO_LARGE", "扫描页像素过大，请缩小后上传", 413)
        pix = page.get_pixmap(matrix=pymupdf.Matrix(2, 2), colorspace=pymupdf.csRGB, clip=region)
        recognized = ocr_image(Image.frombytes("RGB", (pix.width, pix.height), pix.samples))
        lines.extend(dict(line, region=list(region)) for line in recognized)
        value = "\n".join(line["text"] for line in recognized).strip()
        if value:
            normalized = re.sub(r"\s", "", value)
            blocks = [(r, t) for r, t in blocks if re.sub(r"\s", "", t) not in normalized]
            blocks.append((region, value))
    if regions:
        text = "\n".join(value for _, value in sorted(blocks, key=lambda b: (b[0].y0, b[0].x0)))
    return text, lines, "ocr" if sparse else "pdf_text_ocr" if regions else "pdf_text"


def parse_file(path: Path, max_pages=120):
    ext = path.suffix.lower()
    pages = []
    try:
        if ext in {".txt", ".md"}:
            pages = [
                {"page": 1, "text": path.read_text(encoding="utf-8-sig"), "method": "text", "ocr_lines": []}
            ]
        elif ext == ".pdf":
            with pymupdf.open(path) as doc:
                require(not doc.is_encrypted, "ENCRYPTED_PDF", "请先解密 PDF", 422)
                require(len(doc) <= max_pages, "PAGE_LIMIT", f"资料最多 {max_pages} 页", 413)
                for n, page in enumerate(doc):
                    text, lines, method = pdf_page_content(page)
                    pages.append(dict(page=n + 1, text=text, method=method, ocr_lines=lines))
        elif ext in {".ppt", ".pptx"}:
            if ext == ".ppt":
                path = legacy_ppt(path, path.parent)
            with zipfile.ZipFile(path) as z:
                require(
                    sum(info.file_size for info in z.infolist()) <= 150_000_000,
                    "ARCHIVE_TOO_LARGE",
                    "PPTX 解压内容过大",
                    413,
                )
            deck = Presentation(str(path))
            require(len(deck.slides) <= max_pages, "PAGE_LIMIT", "幻灯片页数超过限制", 413)
            for n, slide in enumerate(deck.slides):
                texts, lines = [], []
                for shape in slide.shapes:
                    if shape.has_text_frame:
                        texts.append(shape.text)
                    if shape.has_table:
                        texts.extend(" | ".join(cell.text for cell in row.cells) for row in shape.table.rows)
                    if shape.shape_type == 13:  # Embedded picture, including scanned slides.
                        with Image.open(io.BytesIO(shape.image.blob)) as im:
                            lines.extend(ocr_image(im))
                texts.extend(line["text"] for line in lines)
                pages.append(dict(page=n + 1, text="\n".join(texts), method="pptx", ocr_lines=lines))
        elif ext in {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff", ".bmp"}:
            with Image.open(path) as image:
                require(getattr(image, "n_frames", 1) <= max_pages, "PAGE_LIMIT", "图片页数超过限制", 413)
                for n in range(getattr(image, "n_frames", 1)):
                    image.seek(n)
                    lines = ocr_image(image.copy())
                    pages.append(
                        dict(
                            page=n + 1,
                            text="\n".join(line["text"] for line in lines),
                            method="ocr",
                            ocr_lines=lines,
                        )
                    )
        else:
            raise DomainError("UNSUPPORTED_FILE", "支持 PDF/PPT/PPTX/图片/TXT/MD", 415)
    except DomainError:
        raise
    except Exception as exc:
        raise DomainError("INVALID_FILE", "无法读取文件，请检查格式与内容", 422) from exc
    require(
        any(page["text"].strip() for page in pages),
        "NO_READABLE_CONTENT",
        "未识别到可读文字，请重新扫描",
        422,
    )
    return pages


def structure(material_id, pages):
    chunks, chapters = [], []
    chapter = "正文"
    for page in pages:
        text = page["text"].replace("\x00", "").strip()
        for match in re.finditer(r"[^\n]+(?:\n(?!\n)[^\n]+)*", text):
            # Keep chunks reasonably small; offsets refer to page text exactly.
            start, end = match.span()
            for offset in range(start, end, 800):
                finish = min(end, offset + 800)
                value = text[offset:finish]
                heading = value.splitlines()[0].strip()
                if re.match(r"^(?:#{1,6}\s|第[一二三四五六七八九十\d]+[章节]|\d+(?:\.\d+)*[.、\s])", heading):
                    chapter = heading.lstrip("# ")[:100]
                    chapters.append(dict(title=chapter, page=page["page"]))
                chunks.append(
                    dict(
                        chunk_id=f"{material_id}_p{page['page']}_c{len(chunks) + 1}",
                        page=page["page"],
                        chapter=chapter,
                        text=value,
                        start=offset,
                        end=finish,
                        method=page["method"],
                        needs_confirmation=page["method"] in {"ocr", "pdf_text_ocr"},
                    )
                )
        page["text"] = text
    return chunks, chapters
