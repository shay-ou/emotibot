"""
database.py
Thin SQLite wrapper for EmotiBot check-in logs.
Creates emotibot.db in the same folder on first run.
"""

import sqlite3
from datetime import datetime
from pathlib import Path

DB_PATH = Path(__file__).parent / "emotibot.db"

# columns added after the original release -- init_db() migrates any
# existing emotibot.db in place via ALTER TABLE, so nobody has to delete
# their check-in history to get the new fields.
_NEW_COLUMNS = {
    "sleep_hours": "REAL",
    "vitamin_taken": "INTEGER",
    "physical_symptoms": "TEXT",
    "symptom_flag": "TEXT",
    "emergency_alert": "TEXT",
}


def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS checkins (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            dominant_emotion TEXT,
            emotion_confidence REAL,
            self_reported_mood TEXT,
            mood_flag TEXT,
            water_intake_glasses INTEGER,
            notes TEXT
        )
        """
    )

    existing_cols = {row[1] for row in conn.execute("PRAGMA table_info(checkins)")}
    for col, coltype in _NEW_COLUMNS.items():
        if col not in existing_cols:
            conn.execute(f"ALTER TABLE checkins ADD COLUMN {col} {coltype}")

    conn.commit()
    conn.close()


def log_checkin(dominant_emotion, emotion_confidence, self_reported_mood,
                 mood_flag, water_intake_glasses, sleep_hours=-1,
                 vitamin_taken=None, physical_symptoms="", symptom_flag="normal",
                 emergency_alert="", notes=""):
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        """
        INSERT INTO checkins
            (timestamp, dominant_emotion, emotion_confidence,
             self_reported_mood, mood_flag, water_intake_glasses,
             sleep_hours, vitamin_taken, physical_symptoms, symptom_flag,
             emergency_alert, notes)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            datetime.now().isoformat(timespec="seconds"),
            str(dominant_emotion),
            # cast to native Python types -- numpy scalars (e.g. from
            # DeepFace) get silently stored as BLOB/bytes by sqlite3
            # otherwise, which later breaks JSON serialization
            float(emotion_confidence) if emotion_confidence is not None else 0.0,
            str(self_reported_mood),
            str(mood_flag),
            int(water_intake_glasses) if water_intake_glasses is not None else -1,
            float(sleep_hours) if sleep_hours is not None else -1.0,
            int(bool(vitamin_taken)) if vitamin_taken is not None else None,
            str(physical_symptoms),
            str(symptom_flag),
            str(emergency_alert),
            str(notes),
        ),
    )
    conn.commit()
    conn.close()


def get_all_checkins():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT * FROM checkins ORDER BY timestamp DESC"
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


if __name__ == "__main__":
    init_db()
    print(f"Initialized database at {DB_PATH}")
