from dataclasses import dataclass
from typing import Protocol

from .errors import DomainError, require


@dataclass(frozen=True)
class Identity:
    user_id: str
    course_ids: tuple[str, ...]
    permissions: tuple[str, ...] = ()


class AccessProvider(Protocol):
    """A1 authenticates the token; A2 owns require_course_access, including revoked access.

    Methods are synchronous because all B HTTP routes execute in FastAPI's thread pool.
    Never take a user_id from a request body as an authentication claim.
    """

    def authenticate(self, bearer_token: str) -> Identity: ...

    def require_course_access(self, user_id: str, course_id: str) -> None: ...


class DemoAccessProvider:
    def __init__(self, identities):
        self.identities = identities

    def authenticate(self, bearer_token):
        row = self.identities.get(bearer_token)
        require(row is not None, "UNAUTHENTICATED", "需要有效的 Bearer token", 401)
        return Identity(row["user_id"], tuple(row["course_ids"]), tuple(row.get("permissions", [])))

    def require_course_access(self, user_id, course_id):
        require(
            any(r["user_id"] == user_id and course_id in r["course_ids"] for r in self.identities.values()),
            "COURSE_FORBIDDEN",
            "无课程访问权限",
            403,
        )


class DenyAccessProvider:
    def authenticate(self, bearer_token):
        raise DomainError("AUTH_NOT_CONFIGURED", "请接入甲方 A1/A2，或显式使用 demo 模式", 503)

    def require_course_access(self, user_id, course_id):
        raise DomainError("AUTH_NOT_CONFIGURED", "未配置课程权限校验", 503)
