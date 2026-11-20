# Prototype

The first version of Rualock, kept for reference: a Python script using OpenCV's YuNet (detection)
and SFace (recognition), with a PyObjC status light and a LaunchAgent. The native app in the
repository root replaces it.

```bash
cd prototype
uv sync
uv run facelock enroll      # capture your face
uv run facelock ui          # watch and lock, with the notch status light
```
