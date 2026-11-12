#!/bin/bash
set -e
cd "$(dirname "$0")"
mkdir -p templates
cat > voice_module.py << 'VOICE_MODULE_PYEOF'
"""
voice_module.py
Handles the spoken check-in: EmotiBot asks a question out loud (TTS),
listens for the user's spoken reply (STT), and extracts a structured
value from it (a number of glasses, or a mood keyword).

This is a software-only stand-in for the ESP32 + OLED "Actuate" layer
in the full build -- here the "voice" IS the interaction.

Run standalone to test your mic + speakers before wiring into main.py:
    python voice_module.py
"""

import platform
import re
import time
import subprocess

import speech_recognition as sr

_recognizer = sr.Recognizer()
_IS_MAC = platform.system() == "Darwin"

if not _IS_MAC:
    # pyttsx3 is only needed as a fallback on non-Mac systems; macOS uses
    # the built-in 'say' command instead (see speak() below), which avoids
    # a known pyttsx3/pyobjc driver bug on recent macOS versions.
    import pyttsx3
    _engine = pyttsx3.init()
    _engine.setProperty("rate", 170)

# Words that map to a persistent-distress style flag, per the ppt's
# "never diagnose, just screen and encourage care" principle.
_DISTRESS_WORDS = {
    "anxi", "stress", "worri", "overwhelm", "sad", "down", "low",
    "scare", "panic", "exhaust", "tired", "afraid", "hopeless",
    "depress", "cry", "lonely", "isolat",
}
_POSITIVE_WORDS = {
    "good", "great", "fine", "happy", "okay", "calm", "relax",
    "well", "better", "excited", "peaceful", "content",
}

_NUMBER_WORDS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
}

# symptoms that warrant "contact your provider promptly" rather than a
# routine log entry -- not diagnostic, just a nudge to reach out. This
# is a small, non-exhaustive starter list; a real deployment should have
# this reviewed by a clinician, not just a hardcoded keyword set.
_SEEK_CARE_WORDS = {
    "bleeding", "blurred vision", "severe headache", "severe pain",
    "no movement", "not moving", "hasn't moved", "sudden swelling",
    "can't breathe", "chest pain", "fever", "fainted", "dizzy",
}


def speak(text: str):
    print(f"EmotiBot: {text}")
    if _IS_MAC:
        subprocess.run(["say", text])
    else:
        _engine.say(text)
        _engine.runAndWait()


def listen(timeout=6, phrase_time_limit=8) -> str:
    """Listens on the default mic and returns the recognized text (lowercase),
    or '' if nothing was understood."""
    with sr.Microphone() as source:
        _recognizer.adjust_for_ambient_noise(source, duration=0.5)
        print("Listening...")
        try:
            audio = _recognizer.listen(
                source, timeout=timeout, phrase_time_limit=phrase_time_limit
            )
        except sr.WaitTimeoutError:
            return ""

    try:
        text = _recognizer.recognize_google(audio)
        print(f"You said: {text}")
        return text.lower()
    except (sr.UnknownValueError, sr.RequestError):
        return ""


def _extract_number(text: str):
    """Pulls the first integer out of a spoken reply, digits or words."""
    match = re.search(r"\d+", text)
    if match:
        return int(match.group())
    for word, value in _NUMBER_WORDS.items():
        if word in text.split():
            return value
    return None


def ask_water_intake() -> int:
    speak("How many glasses of water have you had today?")
    reply = listen()
    glasses = _extract_number(reply)
    if glasses is None:
        speak("I didn't catch a number, I'll log that as unknown for now.")
        return -1
    speak(f"Got it, {glasses} glasses logged.")
    return glasses


def ask_sleep() -> float:
    speak("How many hours did you sleep last night?")
    reply = listen()
    hours = _extract_number(reply)
    if hours is None:
        speak("I didn't catch a number, I'll log that as unknown.")
        return -1
    speak(f"Got it, {hours} hours logged.")
    return float(hours)


def ask_vitamin() -> bool:
    speak("Did you take your prenatal vitamin today?")
    reply = listen()
    taken = any(word in reply for word in ("yes", "yeah", "yep", "took", "did"))
    speak("Great, marked as taken." if taken else "Noted, I'll flag that for tomorrow.")
    return taken


def ask_symptoms() -> tuple[str, str]:
    """Returns (raw_reply_text, symptom_flag) where symptom_flag is
    'seek_care' or 'normal'. Non-diagnostic -- just flags a short list of
    symptoms worth mentioning to a provider promptly."""
    speak("Any physical symptoms today, like nausea, cramping, or swelling? "
          "Say 'none' if you're feeling fine.")
    reply = listen()
    flag = "seek_care" if any(word in reply for word in _SEEK_CARE_WORDS) else "normal"
    return reply if reply else "no response captured", flag


def ask_mood() -> tuple[str, str]:
    """Returns (raw_reply_text, mood_flag) where mood_flag is
    'distress', 'positive', or 'neutral' based on simple keyword matching.
    This is a lightweight stand-in for the ppt's NLP sentiment engine."""
    speak("How are you feeling today? Any anxiety or stress you'd like to mention?")
    reply = listen()

    # substring matching (not exact word matching) so variations like
    # "stressful"/"stressed"/"stress" all get caught by one root
    if any(word in reply for word in _DISTRESS_WORDS):
        flag = "distress"
    elif any(word in reply for word in _POSITIVE_WORDS):
        flag = "positive"
    else:
        flag = "neutral"

    return reply if reply else "no response captured", flag


def guide_breathing(cycles: int = 3):
    """A short spoken box-breathing exercise -- the 'physical empathy'
    response for a flagged distress moment. Uses time.sleep so the pacing
    actually matches spoken instructions rather than firing all at once."""
    speak("Let's take a moment together. Find a comfortable position if you can.")
    time.sleep(1.5)
    for _ in range(cycles):
        speak("Breathe in slowly, one, two, three, four.")
        time.sleep(4)
        speak("Hold, one, two, three, four.")
        time.sleep(4)
        speak("Breathe out slowly, one, two, three, four.")
        time.sleep(4)
    speak("Well done. Let's continue.")


if __name__ == "__main__":
    speak("Voice module test. Let's try a check-in.")
    g = ask_water_intake()
    mood_text, flag = ask_mood()
    print(f"\nResult -> water: {g} glasses | mood: '{mood_text}' | flag: {flag}")
VOICE_MODULE_PYEOF
cat > main.py << 'MAIN_PYEOF'
"""
main.py
The 50% software demo loop for EmotiBot:
  1. Observe  -> webcam captures facial emotion for a few seconds
  2. Interact -> robot asks about water, sleep, vitamin, symptoms, and
                 mood, by voice
  3. Decision -> simple rule checks for concerning language / symptoms
  4. Log      -> everything is written to emotibot.db for the dashboard

Run:
    python main.py
Then view the dashboard with:
    python app.py
"""

import database
import emotion_module
import voice_module

# Minimal, non-diagnostic safety net matching the ppt's "Safe Escalation"
# slide: certain phrases bypass the normal flow and show a helpline
# immediately instead of being logged as an ordinary mood entry.
_CRISIS_WORDS = {
    "suicidal", "suicide", "self-harm", "self harm", "hurt myself",
    "harm myself", "kill myself", "end my life", "want to die",
    "going to die", "gonna die", "don't want to be here",
    "not worth living", "no point living", "no point in living",
    "better off dead", "better off without me", "can't go on",
    "cant go on", "give up on life",
}

_HELPLINE_MESSAGE = (
    "I want to make sure you're supported right now. Please reach out to "
    "a trusted person or a professional helpline — you don't have to "
    "handle this alone. In India, iCall is available at 9152987821."
)

_SEEK_CARE_MESSAGE = (
    "Some of what you mentioned is worth telling your doctor or midwife "
    "about promptly, rather than waiting for your next appointment."
)

# Simulated only -- no real message is sent anywhere. A real version would
# need a messaging service (e.g. email via smtplib, or SMS via a provider
# like Twilio) plus a proper consent flow for storing a contact's details.
EMERGENCY_CONTACT_NAME = "your emergency contact"


def run_checkin():
    database.init_db()

    print("\n--- EmotiBot Daily Check-in ---")
    print("Step 1/6: Reading facial expression (look at the camera)...")
    emotion, confidence, _ = emotion_module.capture_emotion(duration_seconds=5)
    if emotion is None:
        print("No face detected — continuing with voice check-in only.")
        emotion, confidence = "unknown", 0.0
    else:
        print(f"Detected dominant emotion: {emotion} ({confidence})")

    voice_module.speak("Hi, let's do your daily check-in.")

    print("Step 2/6: Asking about water intake...")
    water_glasses = voice_module.ask_water_intake()

    print("Step 3/6: Asking about sleep...")
    sleep_hours = voice_module.ask_sleep()

    print("Step 4/6: Asking about prenatal vitamin...")
    vitamin_taken = voice_module.ask_vitamin()

    print("Step 5/6: Asking about physical symptoms...")
    symptom_text, symptom_flag = voice_module.ask_symptoms()
    if symptom_flag == "seek_care":
        voice_module.speak(_SEEK_CARE_MESSAGE)

    print("Step 6/6: Asking about mood...")
    mood_text, mood_flag = voice_module.ask_mood()

    # crisis bypass check — never logged as a routine "distress" entry silently;
    # still logged, but the user is shown a helpline immediately.
    emergency_alert = ""
    if any(phrase in mood_text for phrase in _CRISIS_WORDS):
        voice_module.speak(_HELPLINE_MESSAGE)
        mood_flag = "crisis_escalation"
        emergency_alert = f"[SIMULATED] Would notify {EMERGENCY_CONTACT_NAME} now — mental health crisis phrase detected."
        voice_module.speak(f"For this demo, I would also be notifying {EMERGENCY_CONTACT_NAME} right now.")
    elif symptom_flag == "seek_care":
        emergency_alert = f"[SIMULATED] Would notify {EMERGENCY_CONTACT_NAME} now — symptom flagged for prompt care."

    database.log_checkin(
        dominant_emotion=emotion,
        emotion_confidence=confidence,
        self_reported_mood=mood_text,
        mood_flag=mood_flag,
        water_intake_glasses=water_glasses,
        sleep_hours=sleep_hours,
        vitamin_taken=vitamin_taken,
        physical_symptoms=symptom_text,
        symptom_flag=symptom_flag,
        emergency_alert=emergency_alert,
        notes="",
    )

    if mood_flag == "distress" or (emotion in ("sad", "fear", "angry") and mood_flag != "positive"):
        voice_module.speak(
            "Thanks for sharing. I've noticed you might be feeling stressed — "
            "let's take a short breathing break together."
        )
        voice_module.guide_breathing()
        voice_module.speak("Remember it's okay to reach out to your care provider if this continues.")
    else:
        voice_module.speak("Thanks! Your check-in has been logged. Take care of yourself today.")

    print("\nCheck-in complete and saved. Run 'python app.py' to view the dashboard.")


if __name__ == "__main__":
    run_checkin()
MAIN_PYEOF
cat > app.py << 'APP_PYEOF'
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
APP_PYEOF
cat > templates/dashboard.html << 'TEMPLATES_DASHBOARD_HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>EmotiBot — Wellbeing Log</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,500;9..144,600&family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.4/dist/chart.umd.min.js"></script>
<style>
  :root {
    --bg: #F3F1F7;
    --card: #FFFFFF;
    --ink: #2B2733;
    --ink-soft: #675F73;
    --plum: #7C6A8E;
    --sage: #7E9A82;
    --rose: #C97B6E;
    --line: #E4DFEC;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--ink);
    font-family: 'Inter', sans-serif;
    line-height: 1.5;
  }
  header {
    padding: 48px 32px 32px;
    max-width: 960px;
    margin: 0 auto;
  }
  header h1 {
    font-family: 'Fraunces', serif;
    font-weight: 500;
    font-size: 2.4rem;
    margin: 0 0 6px;
    color: var(--ink);
  }
  header p {
    margin: 0;
    color: var(--ink-soft);
    max-width: 46ch;
  }
  main {
    max-width: 960px;
    margin: 0 auto;
    padding: 0 32px 64px;
  }
  .stats {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 16px;
    margin: 32px 0;
  }
  .tip-card {
    background: linear-gradient(135deg, #EFEAF6, #F6F1EC);
    border: 1px solid var(--line);
    border-radius: 10px;
    padding: 20px 24px;
    margin-top: 8px;
  }
  .tip-label {
    display: block;
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--plum);
    margin-bottom: 6px;
  }
  .tip-card p {
    margin: 0;
    color: var(--ink);
  }
  .stat {
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 10px;
    padding: 20px;
  }
  .stat .value {
    font-family: 'Fraunces', serif;
    font-size: 2rem;
    color: var(--plum);
  }
  .stat .label {
    color: var(--ink-soft);
    font-size: 0.9rem;
  }
  .chart-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    margin-bottom: 32px;
  }
  .chart-card {
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 10px;
    padding: 24px;
  }
  .chart-card h2 {
    font-family: 'Fraunces', serif;
    font-weight: 500;
    font-size: 1.2rem;
    margin: 0 0 16px;
  }
  .chart-card canvas {
    max-height: 220px;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 10px;
    overflow: hidden;
    font-size: 0.85rem;
  }
  th, td {
    text-align: left;
    padding: 10px 12px;
    border-bottom: 1px solid var(--line);
  }
  th {
    color: var(--ink-soft);
    font-weight: 500;
  }
  tr:last-child td { border-bottom: none; }
  .badge {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 20px;
    font-size: 0.8rem;
  }
  .badge.positive { background: #E7EFE8; color: var(--sage); }
  .badge.neutral { background: #EFECF5; color: var(--plum); }
  .badge.distress, .badge.crisis_escalation { background: #F5E7E4; color: var(--rose); }
  .empty {
    padding: 48px;
    text-align: center;
    color: var(--ink-soft);
  }
</style>
</head>
<body>
<header>
  <h1>EmotiBot Wellbeing Log</h1>
  <p>A running record of daily check-ins — facial cues from the webcam
     paired with what you actually said, so nothing gets lost between
     appointments.</p>
</header>
<main>
  <div class="tip-card">
    <span class="tip-label">Tip of the day</span>
    <p>{{ tip_of_the_day }}</p>
  </div>

  <div class="stats">
    <div class="stat">
      <div class="value">{{ total }}</div>
      <div class="label">Check-ins logged</div>
    </div>
    <div class="stat">
      <div class="value">{{ avg_water }}</div>
      <div class="label">Avg. glasses of water / day</div>
    </div>
    <div class="stat">
      <div class="value">{{ avg_sleep }}</div>
      <div class="label">Avg. hours of sleep</div>
    </div>
    <div class="stat">
      <div class="value">{{ vitamin_pct ~ "%" if vitamin_pct is not none else "—" }}</div>
      <div class="label">Vitamin adherence</div>
    </div>
    <div class="stat">
      <div class="value">{{ distress_count }}</div>
      <div class="label">Flagged for gentle follow-up</div>
    </div>
    <div class="stat">
      <div class="value">{{ seek_care_count }}</div>
      <div class="label">Symptoms flagged for provider</div>
    </div>
    <div class="stat">
      <div class="value">{{ alert_count }}</div>
      <div class="label">Emergency contact alerts (simulated)</div>
    </div>
  </div>

  {% if checkins %}
  <div class="chart-row">
    <div class="chart-card">
      <h2>Water intake over time</h2>
      <canvas id="waterChart" height="90"></canvas>
    </div>
    <div class="chart-card">
      <h2>Sleep over time</h2>
      <canvas id="sleepChart" height="90"></canvas>
    </div>
  </div>

  <div class="chart-row">
    <div class="chart-card">
      <h2>Mood check-ins by flag</h2>
      <canvas id="moodChart" height="90"></canvas>
    </div>
    <div class="chart-card">
      <h2>Facial emotion distribution</h2>
      <canvas id="emotionChart" height="90"></canvas>
    </div>
  </div>

  <table>
    <thead>
      <tr>
        <th>When</th>
        <th>Facial cue</th>
        <th>Water</th>
        <th>Sleep</th>
        <th>Vitamin</th>
        <th>Symptoms</th>
        <th>Mood</th>
        <th>Flag</th>
      </tr>
    </thead>
    <tbody>
      {% for c in checkins %}
      <tr>
        <td>{{ c.timestamp }}</td>
        <td>{{ c.dominant_emotion }}</td>
        <td>{{ c.water_intake_glasses if c.water_intake_glasses is not none and c.water_intake_glasses >= 0 else "—" }}</td>
        <td>{{ c.sleep_hours if c.sleep_hours is not none and c.sleep_hours >= 0 else "—" }}</td>
        <td>{{ "Yes" if c.vitamin_taken == 1 else ("No" if c.vitamin_taken == 0 else "—") }}</td>
        <td>
          {{ c.physical_symptoms }}
          {% if c.symptom_flag == "seek_care" %}<span class="badge distress">seek care</span>{% endif %}
          {% if c.get("emergency_alert") %}<br><span class="badge crisis_escalation">contact alerted (sim)</span>{% endif %}
        </td>
        <td>{{ c.self_reported_mood }}</td>
        <td><span class="badge {{ c.mood_flag }}">{{ c.mood_flag }}</span></td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
  {% else %}
  <div class="empty">
    No check-ins yet. Run <code>python main.py</code> to log your first one.
  </div>
  {% endif %}
</main>

<script>
  const checkins = {{ checkins | tojson }};
  if (checkins.length) {
    const ordered = [...checkins].reverse();
    const labels = ordered.map(c => c.timestamp.slice(5, 16));

    new Chart(document.getElementById('waterChart'), {
      type: 'line',
      data: {
        labels: labels,
        datasets: [{
          label: 'Glasses of water',
          data: ordered.map(c => c.water_intake_glasses >= 0 ? c.water_intake_glasses : null),
          borderColor: '#7C6A8E',
          backgroundColor: 'rgba(124,106,142,0.12)',
          tension: 0.3,
          fill: true,
          spanGaps: true,
        }]
      },
      options: {
        maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: { y: { beginAtZero: true } }
      }
    });

    new Chart(document.getElementById('sleepChart'), {
      type: 'line',
      data: {
        labels: labels,
        datasets: [{
          label: 'Hours of sleep',
          data: ordered.map(c => (c.sleep_hours !== undefined && c.sleep_hours >= 0) ? c.sleep_hours : null),
          borderColor: '#7E9A82',
          backgroundColor: 'rgba(126,154,130,0.12)',
          tension: 0.3,
          fill: true,
          spanGaps: true,
        }]
      },
      options: {
        maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: { y: { beginAtZero: true } }
      }
    });

    const moodCounts = {{ mood_counts | tojson }};
    const moodColors = {
      positive: '#7E9A82',
      neutral: '#7C6A8E',
      distress: '#C97B6E',
      crisis_escalation: '#B0453A',
    };
    new Chart(document.getElementById('moodChart'), {
      type: 'bar',
      data: {
        labels: Object.keys(moodCounts),
        datasets: [{
          data: Object.values(moodCounts),
          backgroundColor: Object.keys(moodCounts).map(k => moodColors[k] || '#7C6A8E'),
          borderRadius: 4,
        }]
      },
      options: {
        maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: { y: { beginAtZero: true, ticks: { stepSize: 1 } } }
      }
    });

    const emotionCounts = {{ emotion_counts | tojson }};
    new Chart(document.getElementById('emotionChart'), {
      type: 'bar',
      data: {
        labels: Object.keys(emotionCounts),
        datasets: [{
          data: Object.values(emotionCounts),
          backgroundColor: '#7C6A8E',
          borderRadius: 4,
        }]
      },
      options: {
        indexAxis: 'y',
        maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: { x: { beginAtZero: true, ticks: { stepSize: 1 } } }
      }
    });
  }
</script>
</body>
</html>
TEMPLATES_DASHBOARD_HTMLEOF
echo "Updated: voice_module.py, main.py, app.py, templates/dashboard.html"
grep -c "guide_breathing" main.py
grep -c "tip_of_the_day" app.py
