"""
app.py
Flask dashboard that reads emotibot.db and displays check-in history.
Run:
    python app.py
Then open http://127.0.0.1:5000 in a browser.
"""

from collections import Counter
from datetime import date

from flask import Flask, render_template

import database

app = Flask(__name__)

# General pregnancy wellness tips -- not trimester-specific, rotated daily
# by date so it's a stable "tip of the day" rather than random each refresh.
_TIPS = [
    "Staying hydrated can help reduce common pregnancy fatigue and headaches.",
    "Short, gentle walks are often recommended throughout pregnancy — check with your provider on what's right for you.",
    "It's normal for sleep to get harder as pregnancy progresses; a pillow between the knees can help with comfort.",
    "Talking through anxious thoughts with someone you trust, rather than sitting with them alone, can genuinely help.",
    "Prenatal vitamins are most effective when taken consistently at the same time each day.",
    "Mood swings during pregnancy are common and hormonally driven — they don't mean something is wrong with you.",
    "Eating smaller, more frequent meals can help with nausea for many people.",
    "It's okay to ask for help with everyday tasks — pregnancy is physically demanding even when things are going well.",
    "Keeping a light, consistent bedtime routine can improve sleep quality even if total hours are shorter.",
    "If something feels off, trust that instinct enough to mention it to your provider rather than waiting it out.",
]


def _tip_of_the_day():
    return _TIPS[date.today().toordinal() % len(_TIPS)]


def _avg(values):
    values = [v for v in values if v is not None and v >= 0]
    return round(sum(values) / len(values), 1) if values else 0


@app.route("/")
def dashboard():
    database.init_db()
    checkins = database.get_all_checkins()

    total = len(checkins)
    avg_water = _avg([c["water_intake_glasses"] for c in checkins])
    avg_sleep = _avg([c.get("sleep_hours") for c in checkins])

    vitamin_days = [c for c in checkins if c.get("vitamin_taken") is not None]
    vitamin_pct = (
        round(100 * sum(1 for c in vitamin_days if c["vitamin_taken"]) / len(vitamin_days))
        if vitamin_days else None
    )

    distress_count = len([c for c in checkins if c["mood_flag"] in ("distress", "crisis_escalation")])
    seek_care_count = len([c for c in checkins if c.get("symptom_flag") == "seek_care"])
    alert_count = len([c for c in checkins if c.get("emergency_alert")])

    mood_counts = Counter(c["mood_flag"] for c in checkins)
    emotion_counts = Counter(c["dominant_emotion"] for c in checkins)

    return render_template(
        "dashboard.html",
        checkins=checkins,
        total=total,
        avg_water=avg_water,
        avg_sleep=avg_sleep,
        vitamin_pct=vitamin_pct,
        distress_count=distress_count,
        seek_care_count=seek_care_count,
        alert_count=alert_count,
        tip_of_the_day=_tip_of_the_day(),
        mood_counts=dict(mood_counts),
        emotion_counts=dict(emotion_counts),
    )


if __name__ == "__main__":
    app.run(debug=True)
