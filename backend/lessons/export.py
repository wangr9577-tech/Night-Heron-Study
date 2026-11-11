import os
import subprocess
from pathlib import Path

from backend.engine.db import dumps
from backend.engine.errors import DomainError


def export_pptx(lesson, destination):
    source = destination.with_suffix(".export.json")
    source.write_text(dumps(lesson), encoding="utf-8")
    script = Path(__file__).with_name("export_pptx.mjs")
    try:
        subprocess.run(
            [os.getenv("ZHUOZHI_NODE", "node"), str(script), str(source), str(destination)],
            check=True,
            capture_output=True,
            timeout=100,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise DomainError(
            "PPTX_EXPORT_UNAVAILABLE", "PPT 导出器不可用，请按部署文档配置 Node 渲染器后重试", 503, True
        ) from exc
    finally:
        source.unlink(missing_ok=True)
