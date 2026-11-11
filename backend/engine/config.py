import json
import os
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Settings:
    data_dir: Path = field(default_factory=lambda: Path(os.getenv("ZHUOZHI_DATA_DIR", "data")).resolve())
    mode: str = field(default_factory=lambda: os.getenv("ZHUOZHI_MODE", "integrated"))
    max_upload_mb: int = field(default_factory=lambda: int(os.getenv("ZHUOZHI_MAX_UPLOAD_MB", "30")))
    max_pages: int = field(default_factory=lambda: int(os.getenv("ZHUOZHI_MAX_PAGES", "120")))
    worker_enabled: bool = field(
        default_factory=lambda: os.getenv("ZHUOZHI_WORKER_ENABLED", "true").lower() == "true"
    )
    demo_identities: dict = field(
        default_factory=lambda: json.loads(
            os.getenv(
                "ZHUOZHI_DEMO_IDENTITIES",
                '{"demo-token":{"user_id":"user-demo","course_ids":["course-demo"]},'
                '"other-token":{"user_id":"user-other","course_ids":["course-other"]},'
                '"author-token":{"user_id":"user-demo","course_ids":["course-demo"],"permissions":["assessment:review","content:write"]}}',
            )
        )
    )
