"""Stats tracking with SQLite."""

import sqlite3
import time
from whisprflow.config import DB_PATH


def _connect():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS transcriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            raw_text TEXT NOT NULL,
            polished_text TEXT NOT NULL,
            word_count INTEGER NOT NULL,
            duration_sec REAL NOT NULL,
            app_name TEXT,
            app_bundle_id TEXT
        )
    """)
    conn.commit()
    return conn


def log_transcription(raw: str, polished: str, duration: float, app_info: dict | None = None):
    conn = _connect()
    conn.execute(
        "INSERT INTO transcriptions (timestamp, raw_text, polished_text, word_count, duration_sec, app_name, app_bundle_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (time.time(), raw, polished, len(polished.split()), duration,
         app_info.get("name") if app_info else None,
         app_info.get("bundleId") if app_info else None),
    )
    conn.commit()
    conn.close()


def get_stats() -> dict:
    conn = _connect()
    now = time.time()
    today_start = now - (now % 86400)
    week_start = now - 7 * 86400

    total = conn.execute("SELECT COALESCE(SUM(word_count), 0) FROM transcriptions").fetchone()[0]
    today = conn.execute("SELECT COALESCE(SUM(word_count), 0) FROM transcriptions WHERE timestamp >= ?", (today_start,)).fetchone()[0]
    week = conn.execute("SELECT COALESCE(SUM(word_count), 0) FROM transcriptions WHERE timestamp >= ?", (week_start,)).fetchone()[0]
    count = conn.execute("SELECT COUNT(*) FROM transcriptions").fetchone()[0]
    avg_dur = conn.execute("SELECT COALESCE(AVG(duration_sec), 0) FROM transcriptions").fetchone()[0]

    # Top apps
    top_apps = conn.execute(
        "SELECT app_name, COUNT(*) as cnt FROM transcriptions WHERE app_name IS NOT NULL GROUP BY app_name ORDER BY cnt DESC LIMIT 5"
    ).fetchall()

    conn.close()

    return {
        "words_today": today,
        "words_week": week,
        "words_total": total,
        "transcription_count": count,
        "avg_duration": round(avg_dur, 1),
        "top_apps": top_apps,
        "time_saved_min": round(total * 0.3 / 60, 1),  # ~0.3s per word typing vs instant
    }
