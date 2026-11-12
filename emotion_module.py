"""
emotion_module.py
Captures a short burst of webcam frames, runs DeepFace's emotion model on
each frame, and returns the dominant emotion over the window. This is the
"Observe" + "AI Layer" step from the EmotiBot pipeline (facial cues via webcam).

Uses DeepFace rather than fer -- fer is unmaintained and breaks against
current moviepy/setuptools versions.

Run standalone to sanity-check your webcam + model before wiring it
into main.py:
    python emotion_module.py

The first run downloads DeepFace's pretrained emotion model to ~/.deepface --
keep internet on for that first run only.
"""

import time
from collections import Counter

import cv2
from deepface import DeepFace


def capture_emotion(duration_seconds=5, camera_index=0, show_preview=True):
    """
    Opens the webcam for `duration_seconds`, samples frames, and returns
    (dominant_emotion: str, confidence: float, all_scores: dict).
    Returns (None, 0.0, {}) if no face was detected in any frame.
    """
    cap = cv2.VideoCapture(camera_index)
    if not cap.isOpened():
        raise RuntimeError(
            f"Could not open webcam at index {camera_index}. "
            "Check it isn't in use by another app, and that Terminal has "
            "camera permission in System Settings > Privacy & Security > Camera."
        )

    readings = []
    start = time.time()

    try:
        while time.time() - start < duration_seconds:
            ok, frame = cap.read()
            if not ok:
                continue

            try:
                # enforce_detection=False means "skip this frame quietly if no
                # face found" instead of raising -- important for a live loop.
                result = DeepFace.analyze(
                    frame,
                    actions=["emotion"],
                    enforce_detection=False,
                    silent=True,
                )
            except Exception:
                continue

            # DeepFace returns a list of dicts (one per detected face)
            if isinstance(result, list):
                if not result:
                    continue
                result = result[0]

            emotions = result.get("emotion", {})
            if not emotions:
                continue

            region = result.get("region", {})
            if region.get("w", 0) <= 0:
                continue

            top_emotion = max(emotions, key=emotions.get)
            # DeepFace reports percentages (0-100); normalise to 0-1
            score = emotions[top_emotion] / 100.0
            readings.append((top_emotion, score))

            if show_preview:
                label = f"{top_emotion} ({score:.2f})"
                x, y = region.get("x", 0), region.get("y", 0)
                w, h = region.get("w", 0), region.get("h", 0)
                cv2.rectangle(frame, (x, y), (x + w, y + h), (0, 200, 120), 2)
                cv2.putText(frame, label, (x, max(y - 10, 20)),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 200, 120), 2)

            if show_preview:
                cv2.imshow("EmotiBot - Emotion Check (press q to stop early)", frame)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break
    finally:
        cap.release()
        if show_preview:
            cv2.destroyAllWindows()

    if not readings:
        return None, 0.0, {}

    labels = [r[0] for r in readings]
    dominant = Counter(labels).most_common(1)[0][0]
    avg_confidence = sum(c for l, c in readings if l == dominant) / labels.count(dominant)

    # cast explicitly to a native Python float -- DeepFace/numpy scalar
    # types otherwise slip through as numpy.float64, which sqlite3 silently
    # stores as raw bytes (it treats anything with a buffer-protocol as BLOB)
    return dominant, float(round(avg_confidence, 3)), dict(readings)


if __name__ == "__main__":
    print("Loading model (first run downloads it, be patient)...")
    print("Look at the camera for 5 seconds...")
    emotion, confidence, _ = capture_emotion(duration_seconds=5)
    if emotion:
        print(f"Dominant emotion: {emotion} (confidence {confidence})")
    else:
        print("No face detected. Check lighting/camera position and try again.")
