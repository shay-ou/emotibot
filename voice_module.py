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


def guide_breathing(cycles: int = 1):
    """A short spoken box-breathing exercise -- the 'physical empathy'
    response for a flagged distress moment. Shortened to ~10 seconds total
    for demo purposes; increase cycles/pause_seconds for a real session."""
    pause_seconds = 1.5
    speak("Let's breathe together.")
    for _ in range(cycles):
        speak("Breathe in.")
        time.sleep(pause_seconds)
        speak("Hold.")
        time.sleep(pause_seconds)
        speak("Breathe out.")
        time.sleep(pause_seconds)
    speak("Well done.")


if __name__ == "__main__":
    speak("Voice module test. Let's try a check-in.")
    g = ask_water_intake()
    mood_text, flag = ask_mood()
    print(f"\nResult -> water: {g} glasses | mood: '{mood_text}' | flag: {flag}")
