class DomainError(Exception):
    def __init__(self, code: str, message: str, status: int = 400, retryable: bool = False):
        super().__init__(message)
        self.code, self.message, self.status, self.retryable = code, message, status, retryable


def require(condition, code, message, status=400, retryable=False):
    if not condition:
        raise DomainError(code, message, status, retryable)
