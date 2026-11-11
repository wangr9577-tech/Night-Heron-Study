"""Only integration entry point. A owns the host app, lifespan, auth and deployment.

engine = register_modules(app, Settings(...), access=your_A1_A2_provider)
# In A's lifespan: engine.start(); yield; engine.close()
"""

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from backend.engine.config import Settings
from backend.engine.errors import DomainError
from backend.engine.service import LearningEngine


def register_modules(app: FastAPI, settings: Settings | None = None, access=None):
    engine = LearningEngine(settings or Settings(), access)
    from backend.assessment import router as assessment_router
    from backend.exams import router as exams_router
    from backend.exams import service as exams
    from backend.knowledge import router as knowledge_router
    from backend.lessons import router as lessons_router
    from backend.lessons import service as lessons
    from backend.materials import router as materials_router
    from backend.materials import service as materials
    from backend.mistakes import router as mistakes_router
    from backend.mistakes import service as mistakes
    from backend.review import router as review_router
    from backend.tutoring import router as tutoring_router

    for module in [materials, lessons, exams, mistakes]:
        module.register(engine)
    for module in [
        materials_router,
        knowledge_router,
        tutoring_router,
        lessons_router,
        exams_router,
        mistakes_router,
        assessment_router,
        review_router,
    ]:
        app.include_router(module.router)
    app.state.learning_engine = engine

    @app.exception_handler(DomainError)
    async def domain_error(request: Request, exc: DomainError):
        return JSONResponse(
            status_code=exc.status,
            content={"error": {"code": exc.code, "message": exc.message, "retryable": exc.retryable}},
        )

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request: Request, exc: RequestValidationError):
        return JSONResponse(
            status_code=422,
            content={
                "error": {
                    "code": "VALIDATION_ERROR",
                    "message": "请求字段格式不符合契约",
                    "retryable": False,
                    "details": [{"location": list(e["loc"]), "message": e["msg"]} for e in exc.errors()],
                }
            },
        )

    @app.exception_handler(Exception)
    async def unexpected_error(request: Request, exc: Exception):
        logging.getLogger(__name__).error("Unhandled learning-engine error", exc_info=exc)
        return JSONResponse(
            status_code=500,
            content={
                "error": {"code": "INTERNAL_ERROR", "message": "服务内部错误，请检查日志", "retryable": True}
            },
        )

    return engine
