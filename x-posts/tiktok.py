"""
Send a video to the IEA Kenya TikTok account through TikTok's Content Posting API.

Two modes (TIKTOK_MODE):
  inbox   (default) the video lands in the TikTok app's inbox as a draft; IEA
          Kenya opens the notification, adds the caption and taps Post. Needs
          only the `video.upload` scope and no TikTok audit, and keeps a person
          in the loop as TikTok's sharing guidelines expect.
  direct  posts straight to the profile (`video.publish` scope). Until TikTok
          has audited the app, such posts can only be private (SELF_ONLY).

Credentials (GitHub secrets): TIKTOK_CLIENT_KEY, TIKTOK_CLIENT_SECRET and, the
first time, TIKTOK_REFRESH_TOKEN (from tiktok_auth.py). TikTok may hand back a
new refresh token whenever an access token is issued; the newest one is kept in
the Supabase table `app_tokens` (SQL in README) so it never goes stale.
"""
from __future__ import annotations

import os
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

API = "https://open.tiktokapis.com/v2"
TOKEN_NAME = "tiktok_refresh_token"


class TikTokError(RuntimeError):
    pass


def configured() -> bool:
    return bool(os.getenv("TIKTOK_CLIENT_KEY") and os.getenv("TIKTOK_CLIENT_SECRET")
                and (os.getenv("TIKTOK_REFRESH_TOKEN") or _sb()))


# --- refresh-token store (Supabase table app_tokens) -------------------------
def _sb():
    url, key = os.getenv("SUPABASE_URL", "").rstrip("/"), os.getenv("SUPABASE_SERVICE_ROLE", "")
    return (url, key) if url and key else None


def _stored_token() -> str | None:
    sb = _sb()
    if not sb:
        return None
    try:
        r = requests.get(f"{sb[0]}/rest/v1/app_tokens", params={"name": f"eq.{TOKEN_NAME}", "select": "value"},
                         headers={"apikey": sb[1], "Authorization": f"Bearer {sb[1]}"}, timeout=30)
        rows = r.json() if r.ok else []
        return rows[0]["value"] if rows else None
    except Exception:
        return None


def _store_token(value: str) -> None:
    sb = _sb()
    if not sb:
        return
    requests.post(f"{sb[0]}/rest/v1/app_tokens", json=[{"name": TOKEN_NAME, "value": value,
                                                        "updated_at": datetime.now(timezone.utc).isoformat()}],
                  headers={"apikey": sb[1], "Authorization": f"Bearer {sb[1]}", "Content-Type": "application/json",
                           "Prefer": "resolution=merge-duplicates,return=minimal"}, timeout=30).raise_for_status()


def access_token() -> str:
    refresh = _stored_token() or os.getenv("TIKTOK_REFRESH_TOKEN")
    if not refresh:
        raise TikTokError("no TikTok refresh token: run tiktok_auth.py and set TIKTOK_REFRESH_TOKEN")
    r = requests.post(f"{API}/oauth/token/", timeout=30, headers={"Content-Type": "application/x-www-form-urlencoded"},
                      data={"client_key": os.environ["TIKTOK_CLIENT_KEY"],
                            "client_secret": os.environ["TIKTOK_CLIENT_SECRET"],
                            "grant_type": "refresh_token", "refresh_token": refresh})
    j = r.json()
    if not r.ok or "access_token" not in j:
        raise TikTokError(f"TikTok token refresh failed: {j.get('error_description') or j.get('error') or r.text[:200]}"
                          " (run tiktok_auth.py again if the account's authorisation has expired)")
    if j.get("refresh_token") and j["refresh_token"] != refresh:
        try:
            _store_token(j["refresh_token"])
        except Exception as e:  # posting can still go ahead; next run may need TIKTOK_REFRESH_TOKEN updated
            print(f"Warning: could not save the new TikTok refresh token ({e}).")
    return j["access_token"]


# --- posting ------------------------------------------------------------------
def _post(token: str, path: str, body: dict) -> dict:
    r = requests.post(f"{API}{path}", json=body, timeout=60,
                      headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=UTF-8"})
    j = r.json() if r.content else {}
    err = (j.get("error") or {})
    if not r.ok or (err.get("code") not in (None, "", "ok")):
        raise TikTokError(f"TikTok {path} failed: {err.get('code')} {err.get('message') or r.text[:200]}")
    return j.get("data") or {}


def send_video(mp4: Path, caption: str = "", mode: str | None = None, wait_s: int = 180) -> dict:
    """Upload `mp4`; returns {"mode", "publish_id", "status", "url"}."""
    mode = (mode or os.getenv("TIKTOK_MODE", "inbox")).strip().lower()
    token = access_token()
    size = Path(mp4).stat().st_size
    source = {"source": "FILE_UPLOAD", "video_size": size, "chunk_size": size, "total_chunk_count": 1}
    username = None
    if mode == "direct":
        info = _post(token, "/post/publish/creator_info/query/", {})
        username = info.get("creator_username")
        options = info.get("privacy_level_options") or []
        want = os.getenv("TIKTOK_PRIVACY", "PUBLIC_TO_EVERYONE")
        privacy = want if want in options else ("SELF_ONLY" if "SELF_ONLY" in options else (options or ["SELF_ONLY"])[0])
        data = _post(token, "/post/publish/video/init/", {
            "post_info": {"title": caption[:2200], "privacy_level": privacy, "disable_duet": False,
                          "disable_comment": False, "disable_stitch": False, "video_cover_timestamp_ms": 1500},
            "source_info": source})
    else:
        data = _post(token, "/post/publish/inbox/video/init/", {"source_info": source})
    publish_id, upload_url = data.get("publish_id"), data.get("upload_url")
    if not publish_id or not upload_url:
        raise TikTokError("TikTok returned no upload address")
    with open(mp4, "rb") as fh:
        r = requests.put(upload_url, data=fh.read(), timeout=300,
                         headers={"Content-Type": "video/mp4", "Content-Length": str(size),
                                  "Content-Range": f"bytes 0-{size - 1}/{size}"})
    if not r.ok:
        raise TikTokError(f"TikTok upload failed (HTTP {r.status_code}): {r.text[:200]}")
    status, url, deadline = "PROCESSING_UPLOAD", None, time.time() + wait_s
    while time.time() < deadline:
        time.sleep(6)
        s = _post(token, "/post/publish/status/fetch/", {"publish_id": publish_id})
        status = s.get("status") or status
        if status == "FAILED":
            raise TikTokError(f"TikTok could not process the video: {s.get('fail_reason')}")
        if status in ("SEND_TO_USER_INBOX", "PUBLISH_COMPLETE"):
            ids = s.get("publicaly_available_post_id") or s.get("publicly_available_post_id") or []
            if ids and username:
                url = f"https://www.tiktok.com/@{username}/video/{ids[0]}"
            break
    return {"mode": mode, "publish_id": publish_id, "status": status, "url": url}
