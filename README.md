# EmotiBot

Voice-and-vision wellness check-in system for pregnancy, with a rule-based response engine, local logging, a web dashboard, and an ESP32-driven expressive robot body (OLED face, pan/tilt head, differential-drive base).

Not a medical device. It records observations and applies keyword rules. It does not diagnose.

---

## 1. System overview

```
 Webcam ──┐                                         ┌── OLED face (SSD1306, I2C)
          ├─► HOST (Python) ──USB-UART 115200 8N1──►│── 2x servo (pan, tilt)
 Mic ─────┘   │                                     └── 2x DC motor (diff drive)
              │                                          ESP32 firmware (FreeRTOS)
              ├─► SQLite  ──► Flask dashboard (127.0.0.1)
              └─► Escalation (Telegram → WhatsApp → SMS app → dialer)
```

| Layer | Runs on | Responsibility |
| :-- | :-- | :-- |
| Perception | Host | Face detection, emotion label, speech-to-text |
| Dialogue | Host | Question flow, follow-ups, TTS |
| Rules | Host | Mood, warning-sign, crisis classification, response routing |
| Persistence | Host | SQLite writes |
| Presentation | Host | Flask dashboard |
| Body control | ESP32 | Command validation, display, servo and motor scheduling, watchdog |

The ESP32 only receives compact JSON commands. Raw video and transcripts never cross the serial link.

---

## 2. Repository layout

```
.
├── main.py                 # check-in pipeline entry point
├── app.py                  # Flask dashboard entry point
├── emotibot/
│   ├── vision.py           # capture, Haar detection, DeepFace, majority vote
│   ├── speech.py           # STT (SpeechRecognition), TTS (pyttsx3)
│   ├── dialogue.py         # question flow and follow-ups
│   ├── numbers.py          # regex + word-to-number extraction
│   ├── rules/
│   │   ├── warning.py      # warning-sign engine (4 levels, week rules)
│   │   ├── mood.py         # mood keyword classifier
│   │   └── crisis.py       # crisis phrase list
│   ├── responses.py        # tiered response routing, breathing/grounding scripts
│   ├── escalate.py         # Telegram → WhatsApp → SMS → dialer fallback
│   ├── db.py               # SQLite access
│   └── bodylink.py         # serial command sender, heartbeat, ACK handling
├── templates/ static/      # dashboard (Chart.js)
├── firmware/
│   ├── platformio.ini      # or ESP-IDF project files
│   └── src/
│       ├── main.c          # task creation
│       ├── uart_rx.c       # frame receive + validate
│       ├── mapper.c        # command → actuation profile
│       ├── motor.c         # LEDC PWM + driver direction pins
│       ├── servo.c         # LEDC 50 Hz servo pulses
│       ├── oled.c          # SSD1306 over I2C
│       ├── watchdog.c      # heartbeat timeout
│       └── config.h        # pins and limits
├── tests/                  # rule tests, DB tests, protocol tests
└── README.md
```

---

## 3. Host software

### 3.1 Requirements

- Python 3.10+
- Windows (TTS uses pyttsx3 with SAPI5)
- Webcam (tested spec: 1080p @ 30 fps), USB microphone
- Internet for Google Web Speech API and first-run DeepFace weight download

```bash
python -m venv venv && venv\Scripts\activate
pip install opencv-python deepface SpeechRecognition pyttsx3 pyaudio flask pyserial
```

### 3.2 Run

```bash
python main.py      # one check-in session
python app.py       # dashboard at http://127.0.0.1:5000
```

Say "call my husband" at any point to trigger the contact path.

### 3.3 Configuration

| Key | Meaning | Default |
| :-- | :-- | :-- |
| `CAMERA_INDEX` | OpenCV camera index | 0 |
| `CAPTURE_SECONDS` | Face observation window | 8 |
| `CAPTURE_FPS` | Sampled frames per second | 3 |
| `DB_PATH` | SQLite file | `emotibot.db` |
| `SERIAL_PORT` | Body controller COM port | `COM3` |
| `SERIAL_BAUD` | Baud rate | 115200 |
| `BODY_ENABLED` | Send commands to ESP32 | false |
| `CONTACT_NAME` | Escalation contact label | `husband` |
| `TELEGRAM_*`, `PHONE_NUMBER` | Escalation channels | unset |

### 3.4 Vision pipeline

1. Open camera, apply histogram equalisation to each sampled frame.
2. Detect faces with OpenCV Haar Cascade (Viola-Jones).
3. Run DeepFace emotion CNN on the face crop (7 classes: angry, disgust, fear, happy, sad, surprise, neutral).
4. Over about 24 frames (3 fps × 8 s), take the **majority class**; confidence = mean softmax score of the winning class.
5. Store only `(label, confidence)`. Frames are discarded.
6. Failure states are stored as `NULL`, never as `neutral`: no camera, no face, multiple faces.

The softmax score is a model confidence, not a calibrated probability.

### 3.5 Dialogue flow

| Step | Prompt topic | Parsing |
| :-- | :-- | :-- |
| 1 | Face observation | Section 3.4 |
| 2 | Pregnancy week | Number extraction, stage guidance |
| 3 | Water intake (glasses) | Number extraction |
| 4 | Sleep (hours) | Number extraction |
| 5 | Prenatal vitamin | Yes/no |
| 6 | Physical symptoms | Warning engine; nausea follow-ups (ate recently? feel full?) |
| 7 | Baby movement and warning signs | Warning engine |
| 8 | Physical activity | Yes/no |
| 9 | Mood | Mood classifier, crisis check |

Unparseable numeric answers are stored as `unknown`.

### 3.6 Rule engines

**Warning-sign engine** (`rules/warning.py`)

1. Split the answer into clauses.
2. Drop negated clauses ("no bleeding", "never had any fever").
3. Match grouped keyword rules.
4. Apply week-dependent rules (for example contractions before 37 weeks → urgent).
5. Return the highest level: `none < watch < call_provider < urgent`.

**Mood classifier** (`rules/mood.py`): keyword matching into `distress`, `positive`, `neutral`.
Required fixes: word-boundary matching (so "slowly" does not match "low") and the negation filter from the warning engine (so "I am not sad" is not distress).

**Crisis detector** (`rules/crisis.py`): phrase list; any hit triggers the crisis path.

### 3.7 Response routing

Highest priority wins; all flags are still stored.

```python
if crisis:            response = "crisis"            # helpline + contact draft
elif level in ("call_provider", "urgent"):
                      response = "provider_prompt"   # call doctor/midwife today
elif mood == "distress":
                      response = "breathing"         # 4-4-6 breathing x5, grounding 5-4-3
else:                 response = "routine"
```

Routine means no configured phrase matched. It is not a safety finding.

### 3.8 Escalation chain

Telegram → WhatsApp → SMS app → phone dialer. Each step runs only if the previous fails. The user confirms the final send. Delivery status is not claimed unless the channel returns it.

### 3.9 Database

Reconcile with your actual schema before use.

```sql
CREATE TABLE checkin (
  id INTEGER PRIMARY KEY,
  started_at TEXT NOT NULL,
  preg_week INTEGER,
  expression_label TEXT,
  expression_conf REAL,
  water_answer TEXT, sleep_answer TEXT, vitamin_answer TEXT,
  symptom_text TEXT, warning_text TEXT, activity_answer TEXT, mood_text TEXT,
  warning_level TEXT, mood_flag TEXT, crisis_flag INTEGER,
  response_kind TEXT,
  status TEXT NOT NULL DEFAULT 'completed'   -- completed | interrupted
);
CREATE TABLE flag (
  checkin_id INTEGER NOT NULL REFERENCES checkin(id),
  category TEXT NOT NULL,
  rule_reference TEXT
);
```

Rules: parameterised queries only, one transaction per session, original answer text always kept next to parsed values.

### 3.10 Dashboard

- Needs-attention panel: urgent, call-provider, crisis entries with quoted answers
- Latest check-in
- 12 summary cards: pregnancy week, check-in count, flagged count, water avg, sleep avg, vitamin adherence, activity adherence, symptom flags, face-read success rate, avg emotion confidence, plus two more (confirm against the running app)
- Charts (Chart.js): water trend, sleep trend, facial-cue distribution, mood distribution
- Full log with category badges
- User text is rendered as text, never as HTML

---

## 4. Host ↔ ESP32 protocol

### 4.1 Link

USB-UART bridge, virtual COM port, 115200 baud, 8N1, no flow control.

### 4.2 Frame

Newline-terminated JSON, max 128 bytes, followed by a CRC8 byte field in the JSON.

```json
{"cmd":"face","emotion_state":"neutral","intensity":0,"trimester_flag":null,"seq":42,"crc":"A7"}
```

| Field | Type | Meaning |
| :-- | :-- | :-- |
| `cmd` | string | `face`, `nod`, `shake`, `look`, `move`, `stop`, `hb` (heartbeat) |
| `emotion_state` | string | one of the 7 labels, or `unknown` |
| `intensity` | int 0–100 | scales expression/motion, clamped on the controller |
| `trimester_flag` | int or null | reserved for future content selection |
| `seq` | int | frame counter |
| `crc` | hex string | CRC8 over the frame without the `crc` field |

### 4.3 Acknowledgement

```json
{"ack":42,"state":"accepted"}      // frame valid and queued
{"ack":42,"state":"done"}          // actuation finished
{"ack":42,"state":"rejected","why":"range"}
```

`accepted` is not `done`. The host must not report completed actuation on `accepted`.

### 4.4 Timing (calculated, 8N1, time = 10N / 115200 s)

| Transfer | Wire time |
| :-- | :-- |
| 32-byte frame | 2.78 ms |
| 64-byte frame | 5.56 ms |
| 128-byte frame | 11.11 ms |
| 64-byte command + 16-byte ACK | 6.94 ms |

Measure host-send, controller-receive, accept and observed-output timestamps separately on hardware. The ~15 ms round trip is an unverified estimate.

### 4.5 Failure behaviour

| Failure | Controller action |
| :-- | :-- |
| Bad CRC, malformed, oversized | Reject, no actuation |
| Unknown `cmd` or out-of-range value | Reject, do not default to a motion |
| No heartbeat for 500 ms (tunable) | Stop motors, centre or hold servos, show idle face |
| Link lost, reset, brownout | Boot into non-moving state |
| Queue full | Drop motion requests, keep `stop` highest priority |

---

## 5. Firmware (ESP32)

### 5.1 Toolchain

ESP-IDF (FreeRTOS) or PlatformIO with the ESP-IDF framework.

### 5.2 Tasks

| Task | Priority | Job |
| :-- | :-- | :-- |
| `uart_rx` | High | Read bytes, frame, check CRC, push to queue |
| `mapper` | High | Validate, clamp, map command to an actuation profile |
| `motor` | High | Drive PWM and direction pins, enforce speed and time limits |
| `servo` | Medium | Pan/tilt pulses with travel limits and slew limiting |
| `oled` | Low | Draw face frames over I2C |
| `watchdog` | High | Track last heartbeat, force stop on timeout |

A display update or head animation must never block a `stop`.

### 5.3 Peripherals

| Peripheral | Interface | Notes |
| :-- | :-- | :-- |
| OLED 0.96" SSD1306 128×64 | I2C | Confirm module address (commonly 0x3C) and 3.3 V logic |
| 2× SG90 servos | LEDC PWM, 50 Hz | Measure real travel, set mechanical stops in `config.h` |
| 2× DC gear motors | LEDC PWM + 2 direction pins each | Through motor driver |
| Motor driver | L298N or TB6612FNG | Pick by running and stall current of the chosen motors |

### 5.4 `config.h`

Assign pins after choosing the exact ESP32 board. Avoid strapping pins.

```c
#define PIN_I2C_SDA        /* TBD */
#define PIN_I2C_SCL        /* TBD */
#define PIN_SERVO_PAN      /* TBD */
#define PIN_SERVO_TILT     /* TBD */
#define PIN_MOTOR_L_PWM    /* TBD */
#define PIN_MOTOR_L_IN1    /* TBD */
#define PIN_MOTOR_L_IN2    /* TBD */
#define PIN_MOTOR_R_PWM    /* TBD */
#define PIN_MOTOR_R_IN1    /* TBD */
#define PIN_MOTOR_R_IN2    /* TBD */

#define PAN_MIN_DEG   /* measured */
#define PAN_MAX_DEG   /* measured */
#define TILT_MIN_DEG  /* measured */
#define TILT_MAX_DEG  /* measured */
#define MOTOR_MAX_DUTY     /* bench-tested */
#define MOVE_MAX_MS        /* hard cap per move command */
#define HEARTBEAT_TIMEOUT_MS 500
```

### 5.5 Expression mapping

| `emotion_state` | Face | Head |
| :-- | :-- | :-- |
| neutral | Idle eyes | Hold |
| happy | Smile | Small nod |
| sad | Soft, lowered eyes | Slight tilt down |
| fear, angry | Calm neutral face (do not mirror) | Hold |
| surprise | Wide eyes | Hold |
| unknown | Idle eyes | Hold |

Motion is never derived directly from a facial label or a crisis flag. It comes only from explicit `move` commands that pass range and time limits.

### 5.6 Power

- Battery: chemistry and capacity to be fixed from measured motor stall current plus servo and ESP32 load
- Separate regulated rails: logic (3.3 V), servos, motors
- Common ground across all rails
- Decoupling capacitors at the servo and motor supply; check for brownout resets during motor start
- Hardware emergency-stop switch that cuts motor power independent of firmware

---

## 6. Testing

### 6.1 Software

| Area | Test |
| :-- | :-- |
| Warning engine | Labelled sentences per level, negation, paraphrase, week boundary at 37 |
| Mood classifier | Negation ("not sad"), substring ("slowly"), positive and neutral cases |
| Numbers | Digits, words ("twenty four"), ranges, no number |
| Routing | Overlapping flags: crisis over symptom over mood; all flags stored |
| Vision | No camera, no face, multiple faces → `NULL`, not `neutral` |
| Speech | Unrecognised audio → `unknown`, not an invented answer |
| DB | Round trip, interrupted write, restart, markup in answers |
| Escalation | Fallback order, no false "delivered" claim |

```bash
pytest tests/
```

### 6.2 Hardware bench

1. UART loopback: frame integrity, CRC rejection, oversized frame
2. Heartbeat loss → motors stop within the timeout
3. Servo sweep to measured limits, then lock the limits in `config.h`
4. Motor test on blocks: duty vs speed, stall current, driver temperature
5. Brownout test under simultaneous servo and motor load
6. Emergency-stop switch cuts motor power with firmware hung
7. Latency timestamps at each stage (section 4.4)

### 6.3 Measured results so far (developer-written test sets)

| Component | Result |
| :-- | :-- |
| Warning-sign engine | 39/40 exact level; 13/13 urgent; one under-triage ("my face is swollen" → watch) |
| Mood classifier | 21/25 (negation and substring faults) |
| Number extraction | 11/11 |
| Seek-care flag | 12/12 |
| Emotion CNN | 56.5% on FER-2013 (not measured on this system) |
| Face read, live test | 0/6 (detector fault, re-measure) |
| Speech recognition | Not measured |

Sets are small and written by the rule author, so treat these as functional checks.

---

## 7. Completion checklist

### Software
- [ ] Fix face detection and re-measure read rate and confidence
- [ ] Word-boundary matching and negation filter in mood classifier
- [ ] Add facial-swelling rule at `call_provider`
- [ ] Explicit missing-data states in DB (`NULL`, `status`)
- [ ] Log transcripts and compute word error rate
- [ ] Recompute dashboard values from raw rows; confirm card list
- [ ] Authentication on the dashboard, database encryption
- [ ] Consent flow, retention and delete
- [ ] Independent 100+ sentence test set including Indian English phrasing
- [ ] Cross-day disagreement analysis (declared mapping, window, minimum observations)

### Hardware and firmware
- [ ] Select ESP32 board, assign pins
- [ ] UART receive, CRC, queue, ACK
- [ ] Mapper with range clamps
- [ ] OLED face frames
- [ ] Servo task with travel limits
- [ ] Motor task with duty and time caps
- [ ] Watchdog and stop path
- [ ] Power design and emergency-stop switch
- [ ] Obstacle sensing before autonomous motion
- [ ] End-to-end timing measurements

---

## 8. Limitations

- Keyword rules miss indirect phrasing and some negation; the facial label is not a measure of felt emotion
- Speech recognition needs internet and is untested on accents and noise
- English only, single user, single session
- Laptop-tethered body
- SQLite file is unencrypted and the dashboard has no auth until the checklist items are done
- No clinical validation
