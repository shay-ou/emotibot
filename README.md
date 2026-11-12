# EmotiBot — 50% Software Prototype

Software-only slice of the EmotiBot pipeline: webcam facial-emotion read,
a 5-question spoken check-in, rule-based safety escalation, and a
dashboard where everything gets logged and visualized. No ESP32 / OLED /
servo hardware needed for this milestone — that's the "Actuate" layer
for the second half.

## What each file does
- `emotion_module.py` — opens the webcam, runs the DeepFace emotion model, returns your dominant facial expression.
- `voice_module.py` — speaks questions out loud (text-to-speech), listens to your mic (speech-to-text), and extracts water intake, sleep hours, vitamin taken, physical symptoms, and mood — including a guided breathing exercise for flagged distress.
- `database.py` — SQLite storage (`emotibot.db`, created automatically; existing databases are migrated in place if you already had one from before newer fields existed).
- `main.py` — runs one full check-in: camera → water → sleep → vitamin → symptoms → mood → safety checks → save to DB → spoken reminders.
- `app.py` + `templates/dashboard.html` — local web dashboard with 7 stat tiles, 4 charts, a daily tip, and the full check-in log.

## What the check-in flow actually does
1. Reads your dominant facial expression from a 5-second webcam capture.
2. Asks 5 questions by voice: water intake, sleep hours, prenatal vitamin taken, physical symptoms, and mood.
3. **Two independent safety checks** run against what you said:
   - **Symptom check** — a short list of physical red-flag phrases (bleeding, severe headache, no fetal movement, etc.) sets a `seek_care` flag and a spoken nudge to contact your provider promptly.
   - **Crisis check** — a broader phrase list (e.g. "want to die," "hurt myself") immediately speaks a helpline message and sets `crisis_escalation`, bypassing the normal flow.
4. On a crisis or seek-care flag, it logs and speaks a **simulated** emergency contact notification — no real message is sent anywhere; this is a placeholder for real email/SMS integration.
5. If mood is flagged as ordinary `distress`, it leads a short guided breathing exercise before the closing message.
6. Finally, it checks today's own sleep/vitamin answers and speaks a reminder if sleep was under 6 hours or the vitamin wasn't taken.

## Step 1 — Install Python
You need Python 3.10 or 3.11 (TensorFlow, which DeepFace depends on,
doesn't yet reliably support the very latest Python versions). Check with:
```
python3 --version
```
On Mac, if you need to install 3.11 specifically: `brew install python@3.11`,
then use `python3.11` in place of `python` below.

## Step 2 — Create a virtual environment
```
python3.11 -m venv venv
```
Activate it:
- Windows: `venv\Scripts\activate`
- Mac/Linux: `source venv/bin/activate`

## Step 3 — Install dependencies
On Mac, `pyaudio` needs the `portaudio` system library first:
```
brew install portaudio
export CPPFLAGS=-I$(brew --prefix portaudio)/include
export LDFLAGS=-L$(brew --prefix portaudio)/lib
```
On Windows: `pip install pipwin` then `pipwin install pyaudio` if the plain install fails.
On Linux: `sudo apt-get install portaudio19-dev` first.

Then:
```
pip install -r requirements.txt
```
The first time DeepFace runs it downloads its pretrained emotion model —
keep your internet on for that first run.

## Step 4 — Test the webcam module on its own
```
python emotion_module.py
```
A preview window should open, detect your face, and print your dominant
emotion after 5 seconds. Press `q` to stop early. Adjust lighting/camera
angle if no face is detected. On Mac, allow the camera permission prompt
for Terminal the first time.

## Step 5 — Test the voice module on its own
```
python voice_module.py
```
EmotiBot should speak a question, then listen — answer out loud. Needs a
working mic + speakers and an internet connection (speech recognition
uses Google's free web API).

## Step 6 — Run a full check-in
```
python main.py
```
Walks through all 5 questions, applies the safety checks above, and
saves everything to `emotibot.db`.

## Step 7 — View the dashboard
```
python app.py
```
Open **http://127.0.0.1:5000** in your browser. It shows:
- 7 stat tiles (check-ins logged, avg. water, avg. sleep, vitamin adherence %, distress count, symptoms flagged, simulated emergency alerts)
- Water intake and sleep trend charts
- Mood flag and facial emotion distribution charts
- A rotating "tip of the day"
- The full check-in log with color-coded flags

Run `main.py` a few more times (across sessions) to see the trend charts
fill in.

## Known limits at this 50% stage
- Mood, crisis, and symptom flagging are keyword-based, not a trained
  NLP sentiment model — good enough to demo the loop, not clinically
  validated.
- The emergency contact alert is **simulated only** — it's logged and
  spoken, but no real email/SMS is sent.
- Emotion detection is single-session — no multi-day trend fusion yet
  (that's the "Multi-Day Signal Accumulation" rule from the original
  deck, planned for the next milestone).
- No ESP32/OLED/servo — physical empathy responses are spoken text and
  a guided breathing exercise, not physical actuation, for now.
- Speech recognition needs internet (Google Web Speech API). For an
  offline environment, swap `recognize_google` in `voice_module.py` for
  `recognize_sphinx` (lower accuracy, but works offline).

## Suggested next steps toward 100%
1. Swap keyword-based flagging for a small trained sentiment model on the transcribed text.
2. Add the multi-day persistence rule (only escalate after N flagged days).
3. Wire real messaging (email via `smtplib`, or SMS via a provider like Twilio) for the emergency contact alert.
4. Wire an ESP32 over serial to actually move the servo/OLED based on the mood/symptom flags.
5. Add a consent/privacy screen before the webcam turns on, per the ethics slide.
6. Get the symptom/crisis keyword lists reviewed by someone with clinical background.
