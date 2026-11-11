"""Standalone B verification host. A need not adopt or edit this file."""

from contextlib import asynccontextmanager

from fastapi import FastAPI

from backend.engine.config import Settings
from backend.registration import register_modules


def create_app(settings=None, access=None):
    @asynccontextmanager
    async def lifespan(app):
        app.state.learning_engine.start()
        yield
        app.state.learning_engine.close()

    app = FastAPI(
        title="啄知 AI · 乙方学习引擎",
        version="1.0.0",
        lifespan=lifespan,
        description="B1–B8。独立验证宿主；甲方通过 register_modules 注册。默认拒绝未配置的身份认证。",
    )
    register_modules(app, settings or Settings(), access)

    @app.get("/health", tags=["运行检查"])
    def health():
        return {"status": "ok", "contract_version": "1.0", "mode": app.state.learning_engine.settings.mode}

    return app


app = create_app()
