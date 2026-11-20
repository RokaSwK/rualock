"""Lock the Mac when your face is no longer in front of the webcam.

Detection: YuNet (cv2.FaceDetectorYN). Recognition: SFace (cv2.FaceRecognizerSF).
Both are small ONNX models that run locally on the CPU.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

import cv2
import numpy as np
import Quartz

DATA_DIR = Path.home() / "Library" / "Application Support" / "localsec"
ENROLLMENT = DATA_DIR / "me.npy"
PAUSE_FILE = DATA_DIR / "paused_until"
LOG_FILE = Path.home() / "Library" / "Logs" / "localsec.log"
LABEL = "com.localsec.facelock"
PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
APP = Path.home() / "Applications" / "Localsec.app"

MODELS = {
    "yunet": (
        "face_detection_yunet_2023mar.onnx",
        "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx",
        "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
    ),
    "sface": (
        "face_recognition_sface_2021dec.onnx",
        "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx",
        "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
    ),
}

# OpenCV's recommended cosine-similarity threshold for SFace.
DEFAULT_THRESHOLD = 0.363
DETECT_WIDTH = 640


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


# --------------------------------------------------------------------------- models

def model_path(key: str) -> Path:
    name, url, sha = MODELS[key]
    path = DATA_DIR / name
    if not path.exists():
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        log(f"downloading {name}")
        tmp = path.with_suffix(".part")
        urllib.request.urlretrieve(url, tmp)
        digest = hashlib.sha256(tmp.read_bytes()).hexdigest()
        if digest != sha:
            tmp.unlink()
            sys.exit(f"{name}: checksum mismatch ({digest}); refusing to use it")
        tmp.rename(path)
    return path


class Faces:
    def __init__(self, threshold: float = DEFAULT_THRESHOLD, score: float = 0.6):
        self.det = cv2.FaceDetectorYN.create(str(model_path("yunet")), "", (DETECT_WIDTH, 360), score, 0.3, 5)
        self.rec = cv2.FaceRecognizerSF.create(str(model_path("sface")), "")
        self.threshold = threshold
        self.me: np.ndarray | None = np.load(ENROLLMENT) if ENROLLMENT.exists() else None

    def detect(self, frame: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Return (resized frame, faces[N, 15])."""
        h, w = frame.shape[:2]
        if w != DETECT_WIDTH:
            frame = cv2.resize(frame, (DETECT_WIDTH, round(h * DETECT_WIDTH / w)))
        self.det.setInputSize((frame.shape[1], frame.shape[0]))
        _, faces = self.det.detect(frame)
        return frame, (faces if faces is not None else np.empty((0, 15), np.float32))

    def embed(self, frame: np.ndarray, face: np.ndarray) -> np.ndarray:
        feat = self.rec.feature(self.rec.alignCrop(frame, face)).flatten()
        return feat / np.linalg.norm(feat)

    def similarity(self, frame: np.ndarray, face: np.ndarray) -> float:
        assert self.me is not None
        return float(np.max(self.me @ self.embed(frame, face)))


# --------------------------------------------------------------------------- macOS

_login = ctypes.CDLL("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login")


def lock_screen() -> None:
    if hasattr(_login, "SACLockScreenImmediate"):
        _login.SACLockScreenImmediate()
    else:  # fallback: needs "Require password immediately after screen saver/sleep"
        subprocess.run(["pmset", "displaysleepnow"], check=False)


def screen_locked() -> bool:
    d = Quartz.CGSessionCopyCurrentDictionary()
    return bool(d and d.get("CGSSessionScreenIsLocked", 0))


def pause_window() -> tuple[float, float] | None:
    """(started, until) of the current pause, or None. The file holds "until [started]"."""
    try:
        parts = [float(x) for x in PAUSE_FILE.read_text().split()]
    except (OSError, ValueError):
        return None
    if not parts or time.time() >= parts[0]:
        return None
    until = parts[0]
    started = parts[1] if len(parts) > 1 else until - 15 * 60
    return started, until


def paused() -> bool:
    return pause_window() is not None


def open_camera(index: int) -> cv2.VideoCapture | None:
    cam = cv2.VideoCapture(index)
    if not cam.isOpened():
        cam.release()
        return None
    return cam


# --------------------------------------------------------------------------- commands

def cmd_enroll(args: argparse.Namespace) -> None:
    faces = Faces()
    cam = open_camera(args.camera)
    if cam is None:
        sys.exit("could not open the camera (check System Settings > Privacy & Security > Camera)")
    log(f"look at the camera; capturing {args.samples} samples. Move your head a little.")
    samples: list[np.ndarray] = []
    last = 0.0
    while len(samples) < args.samples:
        ok, raw = cam.read()
        if not ok:
            continue
        frame, found = faces.detect(raw)
        status = f"{len(samples)}/{args.samples}"
        if len(found) == 1 and time.monotonic() - last > 0.25:
            samples.append(faces.embed(frame, found[0]))
            last = time.monotonic()
        elif len(found) > 1:
            status += "  (more than one face: only you, please)"
        if args.window:
            show(frame, found, status)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                sys.exit("cancelled")
    cam.release()
    cv2.destroyAllWindows()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    np.save(ENROLLMENT, np.stack(samples))
    os.chmod(ENROLLMENT, 0o600)
    log(f"saved {len(samples)} face embeddings to {ENROLLMENT}")


def show(frame: np.ndarray, found: np.ndarray, text: str, labels: list[str] | None = None) -> None:
    vis = frame.copy()
    for i, f in enumerate(found):
        x, y, w, h = map(int, f[:4])
        cv2.rectangle(vis, (x, y), (x + w, y + h), (0, 200, 0), 2)
        if labels:
            cv2.putText(vis, labels[i], (x, y - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 200, 0), 2)
    cv2.putText(vis, text, (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)
    cv2.imshow("localsec", vis)


def cmd_preview(args: argparse.Namespace) -> None:
    """Live view with detection boxes and match scores, for tuning."""
    faces = Faces(args.threshold)
    cam = open_camera(args.camera)
    if cam is None:
        sys.exit("could not open the camera")
    while True:
        ok, raw = cam.read()
        if not ok:
            continue
        frame, found = faces.detect(raw)
        labels = []
        for f in found:
            if faces.me is None:
                labels.append(f"{f[14]:.2f}")
            else:
                s = faces.similarity(frame, f)
                labels.append(f"{'me' if s >= faces.threshold else '??'} {s:.2f}")
        show(frame, found, f"{len(found)} face(s) - q to quit", labels)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break
    cam.release()
    cv2.destroyAllWindows()
def iou(a: np.ndarray, b: np.ndarray) -> float:
    ax, ay, aw, ah = a[:4]
    bx, by, bw, bh = b[:4]
    ix = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    return float(inter / (aw * ah + bw * bh - inter + 1e-6))


class Watcher:
    """The watch-and-lock loop. `state`, `absent_for` and `absent` are read by the UI.

    state: starting | watching | absent | paused | locked | nocam
    """

    RECHECK_SECS = 2.0  # re-run recognition on a tracked face at least this often

    def __init__(self, args: argparse.Namespace):
        if not ENROLLMENT.exists() and not args.any_face:
            sys.exit("no enrollment found: run `facelock enroll` first, or pass --any-face")
        self.args = args
        self.absent = args.absent
        self.state = "starting"
        self.absent_for = 0.0
        self.stop = threading.Event()
        self.faces: Faces | None = None
        self._box: np.ndarray | None = None  # last face that matched
        self._box_time = 0.0

    def _present(self, frame: np.ndarray, found: np.ndarray) -> bool:
        assert self.faces is not None
        if self.args.any_face:
            return len(found) > 0
        now = time.monotonic()
        # Cheap path: a face sits where we last recognised you, and the check is recent.
        if self._box is not None and now - self._box_time < self.RECHECK_SECS:
            for f in found:
                if iou(f, self._box) > 0.4:
                    self._box = f
                    return True
        for f in found:
            if self.faces.similarity(frame, f) >= self.faces.threshold:
                self._box, self._box_time = f, now
                return True
        self._box = None
        return False

    def run(self) -> None:
        args = self.args
        self.faces = Faces(args.threshold, args.score)
        mode = "any face" if args.any_face else "enrolled face"
        log(f"watching for {mode}; locking after {args.absent}s absent{' (dry run)' if args.dry_run else ''}")

        cam: cv2.VideoCapture | None = None
        last_seen = last_tick = time.monotonic()
        fails = 0
        period = 1 / args.fps

        def release() -> None:
            nonlocal cam
            if cam is not None:
                cam.release()
                cam = None

        while not self.stop.is_set():
            now = time.monotonic()
            if now - last_tick > 5:  # woke from sleep or stalled: don't count that as absence
                last_seen = now
            last_tick = now

            locked = screen_locked()
            if locked and paused():  # a pause ends when you lock: logging back in resumes watching
                PAUSE_FILE.unlink(missing_ok=True)
                log("screen locked: pause ended")
            if locked or paused():
                self.state = "locked" if locked else "paused"
                self.absent_for = 0.0
                release()
                time.sleep(0.5)
                last_seen = time.monotonic()  # grace period once unlocked / resumed
                continue

            if cam is None:
                cam = open_camera(args.camera)
                if cam is None:
                    self.state = "nocam"
                    log("camera unavailable; retrying in 5s")
                    time.sleep(5)
                    continue
                last_seen = time.monotonic()

            ok, raw = cam.read()
            if not ok:
                fails += 1
                if fails > 20:
                    log("camera stopped returning frames; reopening")
                    release()
                    fails = 0
                time.sleep(period)
                continue
            fails = 0

            frame, found = self.faces.detect(raw)
            present = self._present(frame, found)
            if present:
                last_seen = time.monotonic()
            self.absent_for = time.monotonic() - last_seen
            self.state = "watching" if present or self.absent_for < 1 else "absent"

            if args.verbose:
                log(f"faces={len(found)} present={present} absent_for={self.absent_for:.1f}s")

            if self.absent_for > self.absent:
                if args.dry_run:
                    log("would lock now (dry run)")
                else:
                    log("face gone; locking")
                    release()
                    lock_screen()
                    self.state = "locked"
                    time.sleep(3)
                last_seen = time.monotonic()
                self.absent_for = 0.0
                continue

            time.sleep(period)
        release()


def ensure_camera_access() -> None:
    """Ask for camera permission from the main thread (OpenCV can't from a worker thread).

    Under the LaunchAgent the prompt is attributed to Localsec.app. The watcher keeps
    retrying the camera every few seconds, so this doesn't wait for the answer.
    """
    import AVFoundation as AV

    status = AV.AVCaptureDevice.authorizationStatusForMediaType_(AV.AVMediaTypeVideo)
    if status == AV.AVAuthorizationStatusNotDetermined:
        log("asking for camera permission")
        AV.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AV.AVMediaTypeVideo, lambda granted: log(f"camera permission {'granted' if granted else 'denied'}")
        )
    elif status != AV.AVAuthorizationStatusAuthorized:
        log("camera access denied: allow it in System Settings > Privacy & Security > Camera")
    os.environ["OPENCV_AVFOUNDATION_SKIP_AUTH"] = "1"


def cmd_run(args: argparse.Namespace) -> None:
    watcher = Watcher(args)
    ensure_camera_access()
    watcher.run()


def cmd_ui(args: argparse.Namespace) -> None:
    import island

    watcher = Watcher(args)
    ensure_camera_access()
    island.main(watcher)


def authenticate_async(reason: str, done) -> None:
    """Ask for Touch ID (falls back to the Mac password). Calls done(bool) on a background queue."""
    import LocalAuthentication as LA

    policy = LA.LAPolicyDeviceOwnerAuthentication
    ctx = LA.LAContext.alloc().init()
    ok, err = ctx.canEvaluatePolicy_error_(policy, None)
    if not ok:
        log(f"authentication unavailable: {err}")
        done(False)
        return

    def reply(success, error):
        if not success:
            log(f"authentication failed: {error.localizedDescription() if error else 'cancelled'}")
        done(bool(success))

    ctx.evaluatePolicy_localizedReason_reply_(policy, reason, reply)


def authenticate(reason: str) -> bool:
    result = threading.Event()
    ok = [False]

    def done(success: bool) -> None:
        ok[0] = success
        result.set()

    authenticate_async(reason, done)
    result.wait(300)
    return ok[0]


def set_pause(minutes: float) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    now = time.time()
    PAUSE_FILE.write_text(f"{now + minutes * 60} {now}")
    os.chmod(PAUSE_FILE, 0o600)


def pause_reason(minutes: float) -> str:
    unit = "minute" if minutes == 1 else "minutes"
    return f"pause face lock for {minutes:g} {unit}"


def cmd_pause(args: argparse.Namespace) -> None:
    if not authenticate(pause_reason(args.minutes)):
        sys.exit("not paused: authentication failed")
    set_pause(args.minutes)
    log(f"paused for {args.minutes:g} min (facelock resume to undo)")


def cmd_resume(_: argparse.Namespace) -> None:
    PAUSE_FILE.unlink(missing_ok=True)
    log("resumed")


def build_app() -> Path:
    """Build ~/Applications/Localsec.app: a launcher binary that owns the camera permission."""
    here = Path(__file__).resolve().parent
    contents = APP / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    with (contents / "Info.plist").open("wb") as fh:
        plistlib.dump(
            {
                "CFBundleIdentifier": LABEL,
                "CFBundleName": "Localsec",
                "CFBundleDisplayName": "Localsec",
                "CFBundleExecutable": "localsec",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1",
                "LSUIElement": True,
                "NSCameraUsageDescription": "Localsec watches for your face and locks the Mac when you leave.",
            },
            fh,
        )
    exe = contents / "MacOS" / "localsec"
    subprocess.run(
        [
            "clang", "-O2", "-o", str(exe), str(here / "launcher.c"),
            f'-DPYTHON="{sys.executable}"', f'-DSCRIPT="{here / "facelock.py"}"',
        ],
        check=True,
    )
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", LABEL, str(APP)], check=True)
    return exe


def cmd_install(args: argparse.Namespace) -> None:
    if not ENROLLMENT.exists() and not args.any_face:
        sys.exit("run `facelock enroll` first (or install with --any-face)")
    exe = build_app()
    command = "run" if args.headless else "ui"
    program = [str(exe), command, "--absent", str(args.absent)]
    if args.any_face:
        program.append("--any-face")
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with PLIST.open("wb") as fh:
        plistlib.dump(
            {
                "Label": LABEL,
                "ProgramArguments": program,
                "RunAtLoad": True,
                "KeepAlive": True,
                "ThrottleInterval": 10,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
                "StandardOutPath": str(LOG_FILE),
                "StandardErrorPath": str(LOG_FILE),
            },
            fh,
        )
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True)
    subprocess.run(["launchctl", "bootstrap", domain, str(PLIST)], check=True)
    log(f"installed {APP} and {PLIST}; logs in {LOG_FILE}")


def cmd_uninstall(_: argparse.Namespace) -> None:
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], capture_output=True)
    PLIST.unlink(missing_ok=True)
    shutil.rmtree(APP, ignore_errors=True)
    log("uninstalled")


def main() -> None:
    p = argparse.ArgumentParser(prog="facelock", description=__doc__.splitlines()[0])
    p.add_argument("--camera", type=int, default=0, help="camera index (default 0)")
    sub = p.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("enroll", help="capture your face")
    e.add_argument("--samples", type=int, default=30)
    e.add_argument("--no-window", dest="window", action="store_false")
    e.set_defaults(func=cmd_enroll)

    v = sub.add_parser("preview", help="live view with match scores")
    v.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    v.set_defaults(func=cmd_preview)

    for name, func, help_ in (
        ("run", cmd_run, "watch and lock (no UI)"),
        ("ui", cmd_ui, "watch and lock, with the status pill beside the camera"),
    ):
        r = sub.add_parser(name, help=help_)
        r.add_argument("--absent", type=float, default=8, help="seconds without your face before locking")
        r.add_argument("--fps", type=float, default=4)
        r.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD, help="SFace cosine match threshold")
        r.add_argument("--score", type=float, default=0.6, help="YuNet detection confidence")
        r.add_argument("--any-face", action="store_true", help="any face keeps it unlocked")
        r.add_argument("--dry-run", action="store_true", help="log instead of locking")
        r.add_argument("-v", "--verbose", action="store_true")
        r.set_defaults(func=func)

    pa = sub.add_parser("pause", help="stop watching for a while")
    pa.add_argument("minutes", type=float)
    pa.set_defaults(func=cmd_pause)
    sub.add_parser("resume", help="end a pause").set_defaults(func=cmd_resume)

    i = sub.add_parser("install", help="start at login (LaunchAgent)")
    i.add_argument("--absent", type=float, default=8)
    i.add_argument("--any-face", action="store_true")
    i.add_argument("--headless", action="store_true", help="no status pill")
    i.set_defaults(func=cmd_install)
    sub.add_parser("uninstall", help="remove the LaunchAgent").set_defaults(func=cmd_uninstall)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
