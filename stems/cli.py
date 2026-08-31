"""Command line entry point."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .config import DEFAULT_FORMAT, FORMATS, OUT_DIR


def _reporter():
    """Terminal progress, one line per phase."""
    state = {"downloaded": -1}

    def report(event):
        kind = event.get("kind")
        if kind == "download_start":
            print("Downloading audio...", flush=True)
        elif kind == "download_progress":
            percent = int(event["fraction"] * 100)
            if percent >= state["downloaded"] + 10:
                state["downloaded"] = percent
                print(f"  {percent}%", flush=True)
        elif kind == "download_done":
            mins, secs = divmod(int(event["duration"]), 60)
            print(f'  "{event["title"]}" ({mins}:{secs:02d})\n', flush=True)
        elif kind == "model_load":
            print(f'  loading model {event["model"]}', flush=True)
        elif kind == "stage_start":
            print(
                f'[{event["index"] + 1}/{event["total"]}] {event["title"]}...',
                flush=True,
            )
        elif kind == "stage_done":
            print(f'  -> {", ".join(event["stems"])}\n', flush=True)
        elif kind == "stage_skipped":
            print(f'  skipped {event["stage"]}: {event["reason"]}\n', flush=True)
        elif kind == "encode_start":
            print(f'Encoding {event["count"]} stems as {event["format"]}...', flush=True)
        elif kind == "encode_failed":
            print(f'  warning: could not encode {event["stem"]}', flush=True)
        elif kind == "stem_missing":
            print(f'  warning: {event["file"]} went missing', flush=True)
        elif kind == "analyse_start":
            print("Measuring levels...", flush=True)

    return report


def _megabytes(count: int) -> str:
    return f"{count / 1_048_576:,.0f} MB"


def _recompress(out_dir: Path, audio_format: str) -> int:
    """Re-encode existing tracks in place."""
    from .recompress import convert, job_dirs

    directories = job_dirs(out_dir)
    if not directories:
        print(f"Nothing to recompress in {out_dir}.")
        return 0

    def report(event):
        if event.get("kind") == "warn":
            print(f'  warning: {event["message"]}', flush=True)

    total_before = total_after = 0
    for job_dir in directories:
        print(f"{job_dir.name}...", flush=True)
        result = convert(job_dir, audio_format, progress=report)
        total_before += result["before"]
        total_after += result["after"]
        saved = result["before"] - result["after"]
        print(
            f'  {_megabytes(result["before"])} -> {_megabytes(result["after"])}'
            f" (saved {_megabytes(saved)})",
            flush=True,
        )

    saved = total_before - total_after
    ratio = total_before / total_after if total_after else 1
    print(
        f"\nTotal: {_megabytes(total_before)} -> {_megabytes(total_after)}"
        f" — saved {_megabytes(saved)}, {ratio:.1f}x smaller."
    )
    return 0


def _agent(args) -> int:
    """Poll a deployed server for songs it needs fetched."""
    import getpass
    import os

    from .agent import Agent, Worker, sign_in

    url = args.worker or args.agent
    email = args.email or input("Account email: ").strip()
    password = os.environ.get("MUSICLAB_PASSWORD") or getpass.getpass("Password: ")
    try:
        token = sign_in(url, email, password)
    except Exception as exc:
        print(f"Could not sign in: {exc}", file=sys.stderr)
        return 1

    helper = Worker(url, token) if args.worker else Agent(url, token)
    try:
        helper.run()
    except KeyboardInterrupt:
        print("\nAgent stopped.")
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def _accounts(args) -> int:
    """Account admin. Kept out of the server so it works with it stopped."""
    import getpass
    import os

    from . import auth, users

    try:
        if args.add_user:
            password = getpass.getpass("Password: ")
            if password != getpass.getpass("Repeat: "):
                print("Those did not match.", file=sys.stderr)
                return 1
            user = users.create(args.add_user, password)
            print(f'Created {user["email"]} ({user["id"]})')

        if args.set_password:
            # From the environment when scripted, so it stays out of argv and
            # therefore out of the process list.
            password = os.environ.get("MUSICLAB_PASSWORD") or getpass.getpass("New password: ")
            user = users.set_password(args.set_password, password)
            print(f'Password changed for {user["email"]}')

        if args.claim:
            moved = users.claim(args.claim)
            print(f"Moved {moved} track(s) to {args.claim}.")

        if args.list_users:
            rows = users.listing()
            if not rows:
                print("No accounts yet.")
            else:
                print(f'{"email":<32}{"sign-in":<12}{"tracks":>7}  id')
                print("-" * 72)
                for user in rows:
                    methods = []
                    if user["password_hash"]:
                        methods.append("password")
                    if user["apple_sub"]:
                        methods.append("apple")
                    print(
                        f'{(user["email"] or "-"):<32}{"+".join(methods) or "-":<12}'
                        f'{user["tracks"]:>7}  {user["id"]}'
                    )
            orphans = users.orphan_tracks()
            if orphans:
                print(f"\n{len(orphans)} track(s) predate accounts. Assign them with:")
                print("  python -m stems.cli --claim you@example.com")
    except auth.AuthError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="stems",
        description="Split the music in a YouTube video into separate tracks.",
    )
    parser.add_argument("url", nargs="?", help="YouTube (or other yt-dlp) URL")
    parser.add_argument(
        "-o", "--out", type=Path, default=OUT_DIR, help="output directory"
    )
    parser.add_argument(
        "--no-vocal-split",
        action="store_true",
        help="keep vocals as one stem instead of lead + backing",
    )
    parser.add_argument(
        "--no-drum-split",
        action="store_true",
        help="keep drums as one stem instead of kit pieces",
    )
    parser.add_argument(
        "-f",
        "--format",
        default=DEFAULT_FORMAT,
        choices=list(FORMATS),
        help=f"how stems are stored (default: {DEFAULT_FORMAT})",
    )
    parser.add_argument(
        "--formats", action="store_true", help="list the storage formats and exit"
    )
    parser.add_argument(
        "--recompress",
        action="store_true",
        help="re-encode already separated tracks into --format",
    )
    parser.add_argument(
        "--agent",
        metavar="SERVER_URL",
        help="fetch audio for a deployed server that cannot reach YouTube",
    )
    parser.add_argument(
        "--worker",
        metavar="SERVER_URL",
        help="join the swarm: fetch and separate on this Mac, keeping nothing",
    )
    parser.add_argument("--email", help="account to sign the agent in as")
    parser.add_argument(
        "--serve", action="store_true", help="start the web app instead"
    )
    parser.add_argument(
        "--add-user", metavar="EMAIL", help="create an account (prompts for a password)"
    )
    parser.add_argument(
        "--set-password",
        metavar="EMAIL",
        help="change an account's password (prompts, or reads MUSICLAB_PASSWORD)",
    )
    parser.add_argument(
        "--list-users", action="store_true", help="show accounts and their track counts"
    )
    parser.add_argument(
        "--claim",
        metavar="EMAIL",
        help="move tracks separated before accounts existed to this account",
    )
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument(
        "--no-bonjour",
        action="store_true",
        help="do not advertise on the local network (use when deployed)",
    )
    args = parser.parse_args(argv)

    if args.formats:
        print(f'{"format":<12}{"ext":<8}{"kind":<12}note')
        print("-" * 74)
        for key, fmt in FORMATS.items():
            kind = "lossless" if fmt.lossless else "lossy"
            marker = "  (default)" if key == DEFAULT_FORMAT else ""
            print(f"{key:<12}{fmt.extension:<8}{kind:<12}{fmt.note}{marker}")
        return 0

    if args.agent or args.worker:
        return _agent(args)

    if args.add_user or args.list_users or args.claim or args.set_password:
        return _accounts(args)

    if args.serve:
        from .server import serve

        # None lets STEMS_BONJOUR decide; the flag is an explicit override.
        return serve(port=args.port, bonjour=False if args.no_bonjour else None)

    if args.recompress:
        return _recompress(args.out, args.format)

    if not args.url:
        parser.error("a URL is required (or pass --serve for the web app)")

    from . import pipeline

    try:
        result = pipeline.run(
            args.url,
            out_dir=args.out,
            split_vocals=not args.no_vocal_split,
            split_drums=not args.no_drum_split,
            progress=_reporter(),
            audio_format=args.format,
        )
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130

    manifest = result.manifest
    print(
        f'\nDone in {manifest["elapsed_seconds"]}s'
        f' ({manifest["format"]}) -> {result.job_dir}'
    )
    print(f'\n{"stem":<18}{"peak":>10}{"rms":>10}')
    print("-" * 38)
    for stem in manifest["stems"]:
        marker = "" if stem["leaf"] else "  (combined)"
        peak = f'{stem["peak_db"]} dB' if stem["peak_db"] is not None else "silent"
        rms = f'{stem["rms_db"]} dB' if stem["rms_db"] is not None else "-"
        print(f'{stem["name"]:<18}{peak:>10}{rms:>10}{marker}')

    error = manifest.get("reconstruction_error")
    if error is not None:
        print(f"\nResidual after summing leaf stems: {error:.1%} of the original.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
