from .access import DemoAccessProvider, DenyAccessProvider
from .db import Database
from .jobs import JobQueue


class LearningEngine:
    def __init__(self, settings, access=None):
        self.settings = settings
        self.db = Database(settings.data_dir)
        self.access = access or (
            DemoAccessProvider(settings.demo_identities) if settings.mode == "demo" else DenyAccessProvider()
        )
        self.files = settings.data_dir / "files"
        self.files.mkdir(exist_ok=True)
        self.queue = JobQueue(self)
        from backend.tutoring.model import GroundedModel

        self.model = GroundedModel()

    def start(self):
        if self.settings.worker_enabled:
            self.queue.start()

    def close(self):
        self.queue.close()
