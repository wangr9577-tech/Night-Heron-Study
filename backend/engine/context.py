from fastapi import Depends, Header, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .errors import require

bearer = HTTPBearer(auto_error=False)


def get_engine(request: Request):
    return request.app.state.learning_engine


def identity(engine=Depends(get_engine), credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
    require(
        credentials is not None and credentials.scheme.lower() == "bearer",
        "UNAUTHENTICATED",
        "需要 Bearer token",
        401,
    )
    return engine.access.authenticate(credentials.credentials)


def course_context(course_id: str, engine=Depends(get_engine), actor=Depends(identity)):
    engine.access.require_course_access(actor.user_id, course_id)
    return actor.user_id, course_id


def idempotency_key(value: str | None = Header(default=None, alias="Idempotency-Key")):
    require(value is None or 1 <= len(value) <= 200, "INVALID_IDEMPOTENCY_KEY", "幂等键长度应为 1–200")
    return value


def author_context(course_id: str, engine=Depends(get_engine), actor=Depends(identity)):
    engine.access.require_course_access(actor.user_id, course_id)
    authorize = getattr(engine.access, "require_permission", None)
    if authorize is not None:
        authorize(actor.user_id, course_id, "content:write")
    else:
        require("content:write" in actor.permissions, "AUTHOR_REQUIRED", "需要内容审核权限", 403)
    return actor.user_id, course_id


def reviewer_context(course_id: str, engine=Depends(get_engine), actor=Depends(identity)):
    engine.access.require_course_access(actor.user_id, course_id)
    authorize = getattr(engine.access, "require_permission", None)
    if authorize is not None:
        authorize(actor.user_id, course_id, "assessment:review")
    else:
        require("assessment:review" in actor.permissions, "REVIEWER_REQUIRED", "需要判分审核权限", 403)
    return actor.user_id, course_id
