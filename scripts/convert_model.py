# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["coremltools>=8", "onnx", "onnx2torch", "torch", "numpy<2.4"]
# ///
"""Build SFace.mlpackage, the face-recognition model the app ships with.

Downloads SFace from the OpenCV model zoo (Apache-2.0), checks its pinned SHA-256 and
converts it to Core ML. Input "face": 1x3x112x112 RGB, 0-255, aligned with the standard
5-point template. Output "embedding": 128 floats.

    uv run scripts/convert_model.py build/SFace.mlpackage
"""

import hashlib
import sys
import tempfile
import urllib.request
from pathlib import Path

URL = "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx"
SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"


def fetch(cache: Path) -> Path:
    path = cache / "face_recognition_sface_2021dec.onnx"
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != SHA256:
        print(f"downloading {URL}", file=sys.stderr)
        urllib.request.urlretrieve(URL, path)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != SHA256:
        path.unlink()
        sys.exit(f"SFace checksum mismatch ({digest}); refusing to use it")
    return path


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/SFace.mlpackage")
    cache = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(tempfile.gettempdir())

    import coremltools as ct
    import onnx
    import onnx2torch
    import torch

    model = onnx2torch.convert(onnx.load(fetch(cache))).eval()
    example = torch.rand(1, 3, 112, 112) * 255
    traced = torch.jit.trace(model, example)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="face", shape=(1, 3, 112, 112))],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    ml.short_description = "SFace face embedding (OpenCV model zoo, Apache-2.0)"
    out.parent.mkdir(parents=True, exist_ok=True)
    ml.save(str(out))
    print(out)


if __name__ == "__main__":
    main()
