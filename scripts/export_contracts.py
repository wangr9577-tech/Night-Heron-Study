import json
from pathlib import Path

from backend.app import create_app
from backend.engine.config import Settings
from contracts import models


def main():
    app = create_app(Settings(data_dir=Path("tmp/contract-check"), worker_enabled=False))
    root = Path("contracts")
    (root / "openapi.json").write_text(
        json.dumps(app.openapi(), ensure_ascii=False, indent=2), encoding="utf-8"
    )
    schemas = {
        name: value.model_json_schema()
        for name, value in vars(models).items()
        if isinstance(value, type)
        and issubclass(value, models.BaseModel)
        and name not in {"BaseModel", "Input"}
    }
    (root / "schemas.json").write_text(json.dumps(schemas, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Exported {len(app.openapi()['paths'])} paths, {len(schemas)} shared schemas")


if __name__ == "__main__":
    main()
