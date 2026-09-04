"""Put the notarized worker in R2.

    R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... \
        uv run --with boto3 packaging/upload_release.py

Wrangler refuses anything over 300 MiB and the bundle is 330, so this goes
through R2's S3 API, which splits the upload into parts. The credentials are
read from the environment and never written anywhere.

Make the token at: Cloudflare dashboard > R2 > API > Manage API Tokens,
with "Object Read & Write" on the musiclab-downloads bucket.
"""

import os
import sys
import threading
from pathlib import Path

import boto3
from boto3.s3.transfer import TransferConfig

ACCOUNT = "5c16a3f67b5851cf42828b7c52ee53e6"
BUCKET = "musiclab-downloads"
KEY = "Musiclab-Worker.zip"
ARCHIVE = Path(__file__).resolve().parent.parent / "dist" / KEY


class Progress:
    """One line, rewritten, so a five minute upload does not scroll."""

    def __init__(self, total: int) -> None:
        self.total, self.seen, self.lock = total, 0, threading.Lock()

    def __call__(self, chunk: int) -> None:
        with self.lock:
            self.seen += chunk
            done = self.seen / self.total
            sys.stdout.write(
                f"\r  {self.seen / 1048576:6.0f} / {self.total / 1048576:.0f} MiB"
                f"  [{'=' * int(done * 30):30}] {done:4.0%}"
            )
            sys.stdout.flush()


def main() -> int:
    key_id = os.environ.get("R2_ACCESS_KEY_ID")
    secret = os.environ.get("R2_SECRET_ACCESS_KEY")
    if not key_id or not secret:
        print("Set R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY.", file=sys.stderr)
        return 1
    if not ARCHIVE.exists():
        print(f"No archive at {ARCHIVE}. Run sign_and_notarize.sh first.",
              file=sys.stderr)
        return 1

    size = ARCHIVE.stat().st_size
    print(f"==> Uploading {ARCHIVE.name} ({size / 1048576:.0f} MiB) to {BUCKET}")

    s3 = boto3.client(
        "s3",
        endpoint_url=f"https://{ACCOUNT}.r2.cloudflarestorage.com",
        aws_access_key_id=key_id,
        aws_secret_access_key=secret,
        region_name="auto",
    )
    s3.upload_file(
        str(ARCHIVE), BUCKET, KEY,
        ExtraArgs={"ContentType": "application/zip"},
        Callback=Progress(size),
        Config=TransferConfig(multipart_threshold=64 * 1048576,
                              multipart_chunksize=64 * 1048576,
                              max_concurrency=4),
    )
    print("\n==> Done. It should now answer at:")
    print(f"    https://downloads.jetsons.info/{KEY}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
