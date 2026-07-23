"""Downloads and verifies the Freedoom release, extracting freedoom1.wad
into freedoom/. The WAD itself isn't committed to the repo (it's ~28MB and
trivially re-fetchable), so run this once before tools/build.py.
"""
from __future__ import annotations

import hashlib
import io
import os
import urllib.request
import zipfile

VERSION = "0.13.0"
BASE_URL = f"https://github.com/freedoom/freedoom/releases/download/v{VERSION}"
ZIP_NAME = f"freedoom-{VERSION}.zip"
CHECKSUM_NAME = f"freedoom-{VERSION}-CHECKSUM"
DEST_DIR = "freedoom"
WAD_NAME = "freedoom1.wad"


def main():
    os.makedirs(DEST_DIR, exist_ok=True)
    wad_path = os.path.join(DEST_DIR, WAD_NAME)
    if os.path.exists(wad_path):
        print(f"{wad_path} already present, skipping download.")
        return

    print(f"Downloading {CHECKSUM_NAME}...")
    checksum_text = urllib.request.urlopen(f"{BASE_URL}/{CHECKSUM_NAME}").read().decode("ascii")
    expected_sha256 = None
    for line in checksum_text.splitlines():
        if ZIP_NAME in line:
            expected_sha256 = line.split("=")[-1].strip()
    if not expected_sha256:
        raise RuntimeError(f"Could not find checksum for {ZIP_NAME}")

    print(f"Downloading {ZIP_NAME}...")
    zip_bytes = urllib.request.urlopen(f"{BASE_URL}/{ZIP_NAME}").read()

    actual_sha256 = hashlib.sha256(zip_bytes).hexdigest()
    if actual_sha256 != expected_sha256:
        raise RuntimeError(f"Checksum mismatch: expected {expected_sha256}, got {actual_sha256}")
    print("Checksum verified.")

    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        inner_path = f"freedoom-{VERSION}/{WAD_NAME}"
        with zf.open(inner_path) as src, open(wad_path, "wb") as dst:
            dst.write(src.read())

    print(f"Wrote {wad_path}")


if __name__ == "__main__":
    main()
