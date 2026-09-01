"""Sign-up, sign-in, Apple sign-in and password reset."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel

from . import auth, db

router = APIRouter(prefix="/api/auth", tags=["auth"])


class Credentials(BaseModel):
    email: str
    password: str
    display_name: str | None = None


class AppleCredentials(BaseModel):
    identity_token: str
    # Apple sends the name and email only on the very first authorisation,
    # so the app forwards them and we keep them if we have nothing already.
    email: str | None = None
    display_name: str | None = None


class ResetRequest(BaseModel):
    email: str


class ResetConfirm(BaseModel):
    email: str
    code: str
    new_password: str


def _public(user: dict) -> dict:
    return {
        "id": user["id"],
        "email": user["email"],
        "display_name": user["display_name"],
        "has_password": bool(user["password_hash"]),
        "apple_linked": bool(user["apple_sub"]),
    }


def _session_response(user: dict) -> dict:
    return {"token": auth.issue_session(user["id"]), "user": _public(user)}


def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Sign in to continue.")
    return authorization.split(" ", 1)[1].strip()


def _authenticate(authorization: str | None) -> tuple[dict, str]:
    token = _bearer(authorization)
    user = auth.user_for_token(token)
    if user is None:
        raise HTTPException(401, "Your session has expired. Sign in again.")
    return user, token


def current_user(authorization: str | None = Header(default=None)) -> dict:
    """Every route that acts on someone's account depends on this.

    A worker token is deliberately refused here. A Mac doing separation work
    has no business reading the library, changing the password, or minting
    more tokens -- that is the whole point of giving it its own credential
    rather than a copy of the owner's sign-in.
    """
    user, _ = _authenticate(authorization)
    if user.get("token_scope") == "worker":
        raise HTTPException(403, "This token may only run separation work.")
    return user


def worker_user(authorization: str | None = Header(default=None)) -> dict:
    """For the endpoints a helper machine needs: claim work, hand it back.

    A full sign-in is accepted too, so `--worker` still runs from a checkout
    without pairing first.
    """
    user, token = _authenticate(authorization)
    auth.touch(token)
    return user


@router.post("/signup")
def signup(body: Credentials):
    try:
        email = auth.normalise_email(body.email)
        password_hash = auth.hash_password(body.password)
    except auth.AuthError as exc:
        raise HTTPException(400, str(exc)) from exc

    if db.user_by_email(email):
        raise HTTPException(409, "An account with that email already exists.")

    user = db.create_user(
        email=email, password_hash=password_hash, display_name=body.display_name
    )
    return _session_response(user)


@router.post("/login")
def login(body: Credentials):
    try:
        email = auth.normalise_email(body.email)
    except auth.AuthError as exc:
        raise HTTPException(400, str(exc)) from exc

    user = db.user_by_email(email)
    # Same message either way: which half was wrong is not the caller's business.
    if user is None or not auth.verify_password(body.password, user["password_hash"]):
        raise HTTPException(401, "Wrong email or password.")
    return _session_response(user)


@router.post("/apple")
def apple(body: AppleCredentials):
    try:
        claims = auth.verify_apple_token(body.identity_token)
    except auth.AuthError as exc:
        raise HTTPException(401, str(exc)) from exc

    apple_sub = claims["sub"]
    email = claims.get("email") or body.email
    user = db.user_by_apple(apple_sub)

    if user is None and email:
        # Someone who signed up by email and later used Apple is the same
        # person, so link rather than create a second account.
        try:
            existing = db.user_by_email(auth.normalise_email(email))
        except auth.AuthError:
            existing = None
        if existing:
            db.attach_apple(existing["id"], apple_sub)
            user = db.get_user(existing["id"])

    if user is None:
        user = db.create_user(
            email=auth.normalise_email(email) if email else None,
            apple_sub=apple_sub,
            display_name=body.display_name,
        )
    return _session_response(user)


@router.post("/reset/request")
def request_reset(body: ResetRequest):
    try:
        email = auth.normalise_email(body.email)
    except auth.AuthError as exc:
        raise HTTPException(400, str(exc)) from exc
    auth.start_password_reset(email)
    # Deliberately identical whether or not the account exists.
    return {"sent": True, "email_configured": auth.smtp_configured()}


@router.post("/reset/confirm")
def confirm_reset(body: ResetConfirm):
    try:
        user = auth.complete_password_reset(body.email, body.code, body.new_password)
    except auth.AuthError as exc:
        raise HTTPException(400, str(exc)) from exc
    return _session_response(user)


class PairClaim(BaseModel):
    code: str
    label: str = ""
    machine: str = ""


@router.post("/pair")
def start_pair(user: dict = Depends(current_user)):
    """Mint a pairing code. Shown in the app, typed into a worker."""
    code, ttl = auth.start_pairing(user["id"])
    return {"code": code, "expires_in": ttl}


@router.post("/pair/claim")
def claim_pair(body: PairClaim):
    """Unauthenticated on purpose: holding the code is the credential."""
    try:
        token = auth.complete_pairing(body.code, body.label, body.machine)
    except auth.AuthError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"token": token}


@router.get("/pairings")
def list_pairings(user: dict = Depends(current_user)):
    """The Macs paired to this account, newest first."""
    return db.sessions_with_scope(user["id"], "worker")


@router.delete("/pairings/{session_id}")
def revoke_pairing(session_id: str, user: dict = Depends(current_user)):
    if not db.delete_session_by_id(user["id"], session_id):
        raise HTTPException(404, "No such paired machine.")
    return {"ok": True}


@router.get("/me")
def me(user: dict = Depends(current_user)):
    return _public(user)


@router.post("/logout")
def logout(authorization: str | None = Header(default=None)):
    if authorization and authorization.lower().startswith("bearer "):
        auth.revoke(authorization.split(" ", 1)[1].strip())
    return {"ok": True}
