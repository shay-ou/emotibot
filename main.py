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
EMERGENCY_CONTACT_NAME = "husband"


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

    # simple same-day reminders based on today's own answers -- not a
    # scheduled/background notification (that would need OS-level
    # scheduling like cron or launchd, out of scope for this demo)
    if 0 <= sleep_hours < 6:
        voice_module.speak("You got less than six hours of sleep — try to prioritize rest tonight.")
    if vitamin_taken is False:
        voice_module.speak("Also, don't forget your prenatal vitamin today if you haven't taken it yet.")

    print("\nCheck-in complete and saved. Run 'python app.py' to view the dashboard.")


if __name__ == "__main__":
    run_checkin()
