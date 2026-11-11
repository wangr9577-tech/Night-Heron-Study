"""Apply only B-owned migrations; safe to repeat."""

from backend.engine.config import Settings
from backend.engine.db import Database

if __name__ == "__main__":
    db = Database(Settings().data_dir)
    with db.connect() as c:
        print([dict(row) for row in c.execute("SELECT * FROM b_schema_migrations")])
