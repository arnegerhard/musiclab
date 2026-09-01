"""Passwords, sessions, Sign in with Apple, and reset emails."""

from __future__ import annotations

import hashlib
import hmac
import os
import re
import secrets
import smtplib
import ssl
import time
from email.message import EmailMessage

from . import db

# scrypt is in the standard library and memory-hard, so no extra dependency
# is needed to store passwords properly.
SCRYPT_N, SCRYPT_R, SCRYPT_P = 2 ** 15, 8, 1
# scrypt needs 128 * N * r bytes; OpenSSL's default ceiling is exactly that,
# so it has to be raised explicitly or the hash refuses to run.
SCRYPT_MAXMEM = 128 * SCRYPT_N * SCRYPT_R * 2
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys"
APPLE_ISSUER = "https://appleid.apple.com"
APPLE_BUNDLE_ID = os.environ.get("MUSICLAB_BUNDLE_ID", "info.jetsons.musiclab")


class AuthError(Exception):
    """Raised for anything the caller is allowed to see."""


# MARK: passwords

def hash_password(password: str) -> str:
    if len(password) < 8:
        raise AuthError("Password must be at least 8 characters.")
    salt = secrets.token_bytes(16)
    key = hashlib.scrypt(
        password.encode(), salt=salt, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P,
        dklen=32, maxmem=SCRYPT_MAXMEM,
    )
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${salt.hex()}${key.hex()}"


def verify_password(password: str, stored: str | None) -> bool:
    if not stored:
        return False
    try:
        scheme, n, r, p, salt_hex, key_hex = stored.split("$")
        if scheme != "scrypt":
            return False
        key = hashlib.scrypt(
            password.encode(), salt=bytes.fromhex(salt_hex),
            n=int(n), r=int(r), p=int(p), dklen=len(key_hex) // 2,
            maxmem=128 * int(n) * int(r) * 2,
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(key.hex(), key_hex)


def normalise_email(email: str) -> str:
    email = (email or "").strip().lower()
    if not EMAIL_PATTERN.match(email):
        raise AuthError("That does not look like an email address.")
    return email


# MARK: sessions

def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def issue_session(
    user_id: str, scope: str = "full", label: str | None = None
) -> str:
    """Return the bearer token. Only its hash is stored, so a stolen database
    does not hand over live sessions."""
    token = secrets.token_urlsafe(32)
    db.create_session(user_id, _token_hash(token), scope=scope, label=label)
    return token


def user_for_token(token: str) -> dict | None:
    return db.session_user(_token_hash(token)) if token else None


def revoke(token: str) -> None:
    db.delete_session(_token_hash(token))


def touch(token: str) -> None:
    db.touch_session(_token_hash(token))


# MARK: pairing a worker

PAIR_TTL_SECONDS = 10 * 60
# No 0/O or 1/I: this gets read off a phone and typed into a Mac.
_PAIR_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def start_pairing(user_id: str) -> tuple[str, float]:
    """Mint a short code that a worker can trade for its own token.

    The code is stored only as a hash, like every other credential here, and
    is good for one machine -- claiming it deletes it.
    """
    raw = "".join(secrets.choice(_PAIR_ALPHABET) for _ in range(8))
    code = f"{raw[:4]}-{raw[4:]}"
    db.create_pair_code(user_id, _token_hash(normalise_pair_code(code)), PAIR_TTL_SECONDS)
    return code, PAIR_TTL_SECONDS


def normalise_pair_code(code: str) -> str:
    """Accept it typed with or without the dash, in any case."""
    return (code or "").strip().upper().replace("-", "").replace(" ", "")


def complete_pairing(code: str, label: str) -> str:
    """Trade a code for a worker-scoped token. Raises if it is wrong, already
    used, or older than PAIR_TTL_SECONDS."""
    cleaned = normalise_pair_code(code)
    if not cleaned:
        raise AuthError("Enter the pairing code from the app.")
    row = db.take_pair_code(_token_hash(cleaned))
    if row is None:
        raise AuthError("That code is not valid or has expired.")
    return issue_session(row["user_id"], scope="worker", label=label.strip() or "A Mac")


# MARK: Sign in with Apple

_apple_keys: dict = {"fetched_at": 0.0, "jwks": None}


def _apple_jwks():
    """Apple rotates its signing keys, so refresh hourly."""
    import json
    import urllib.request

    if _apple_keys["jwks"] and time.time() - _apple_keys["fetched_at"] < 3600:
        return _apple_keys["jwks"]
    with urllib.request.urlopen(APPLE_KEYS_URL, timeout=10) as response:
        jwks = json.load(response)
    _apple_keys.update(jwks=jwks, fetched_at=time.time())
    return jwks


def verify_apple_token(identity_token: str) -> dict:
    """Check Apple's identity token and return its claims.

    The signature must verify against Apple's published keys, and the audience
    must be this app -- otherwise a token minted for some other app would work.
    """
    import jwt
    from jwt.algorithms import RSAAlgorithm

    try:
        header = jwt.get_unverified_header(identity_token)
        key_data = next(
            (k for k in _apple_jwks()["keys"] if k["kid"] == header.get("kid")), None
        )
        if key_data is None:
            raise AuthError("Apple sign-in key not recognised.")
        public_key = RSAAlgorithm.from_jwk(key_data)
        claims = jwt.decode(
            identity_token,
            public_key,
            algorithms=["RS256"],
            audience=APPLE_BUNDLE_ID,
            issuer=APPLE_ISSUER,
        )
    except AuthError:
        raise
    except Exception as exc:
        raise AuthError(f"Apple sign-in could not be verified: {exc}") from exc

    if not claims.get("sub"):
        raise AuthError("Apple sign-in returned no user identifier.")
    return claims


# MARK: email

def smtp_configured() -> bool:
    return bool(os.environ.get("SMTP_HOST"))


def send_email(to: str, subject: str, body: str) -> None:
    host = os.environ.get("SMTP_HOST")
    if not host:
        # Without SMTP the code still exists; print it so a single-user server
        # is not locked out by having no mail configured.
        print(f"[email not configured] to {to}: {subject}\n{body}", flush=True)
        return

    port = int(os.environ.get("SMTP_PORT", "587"))
    user = os.environ.get("SMTP_USER")
    password = os.environ.get("SMTP_PASSWORD")
    sender = os.environ.get("SMTP_FROM", user or f"musiclab@{host}")

    message = EmailMessage()
    message["From"] = sender
    message["To"] = to
    message["Subject"] = subject
    message.set_content(body)

    context = ssl.create_default_context()
    if port == 465:
        with smtplib.SMTP_SSL(host, port, context=context, timeout=20) as server:
            if user:
                server.login(user, password or "")
            server.send_message(message)
    else:
        with smtplib.SMTP(host, port, timeout=20) as server:
            server.starttls(context=context)
            if user:
                server.login(user, password or "")
            server.send_message(message)


def start_password_reset(email: str) -> None:
    """Always silent about whether the address exists, so this cannot be used
    to discover who has an account."""
    user = db.user_by_email(email)
    if user is None:
        return
    code = f"{secrets.randbelow(10 ** 6):06d}"
    db.store_reset(user["id"], _token_hash(code))
    send_email(
        email,
        "Your Musiclab reset code",
        f"Your password reset code is {code}\n\n"
        "It expires in 15 minutes. If you did not ask for it, ignore this email.",
    )


def complete_password_reset(email: str, code: str, new_password: str) -> dict:
    user = db.user_by_email(normalise_email(email))
    if user is None:
        raise AuthError("That code is not valid.")
    if db.count_reset_attempts(user["id"]) >= 5:
        raise AuthError("Too many attempts. Request a new code.")
    db.record_reset_attempt(user["id"])

    matched = db.consume_reset(_token_hash(code.strip()))
    if matched is None or matched["id"] != user["id"]:
        raise AuthError("That code is not valid or has expired.")

    db.set_password(user["id"], hash_password(new_password))
    return matched
