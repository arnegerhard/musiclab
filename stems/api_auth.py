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


def current_user(authorization: str | None = Header(default=None)) -> dict:
    """Every protected route depends on this."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Sign in to continue.")
    user = auth.user_for_token(authorization.split(" ", 1)[1].strip())
    if user is None:
        raise HTTPException(401, "Your session has expired. Sign in again.")
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


@router.get("/me")
def me(user: dict = Depends(current_user)):
    return _public(user)


@router.post("/logout")
def logout(authorization: str | None = Header(default=None)):
    if authorization and authorization.lower().startswith("bearer "):
        auth.revoke(authorization.split(" ", 1)[1].strip())
    return {"ok": True}
