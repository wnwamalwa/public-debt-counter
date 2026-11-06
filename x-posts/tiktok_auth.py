"""
One-time: let the X posts workflow send videos to the IEA Kenya TikTok account.

Run on your own computer (needs only Python 3):
    python3 tiktok_auth.py

It asks for the TikTok app's Client key and Client secret (TikTok for
Developers -> your app -> App details), prints a link to open while signed in
to the IEA Kenya TikTok account, and after you approve, asks you to paste the
address the browser lands on. It then prints the refresh token to save as the
GitHub secret TIKTOK_REFRESH_TOKEN. Nothing is stored on disk.

The redirect URI below must be listed exactly under Login Kit -> Redirect URI
in the TikTok app.
"""
import getpass
import json
import secrets
import urllib.parse
import urllib.request

REDIRECT_URI = "https://kenyadebtcounter.vercel.app/"
SCOPES = "user.info.basic,video.upload"   # add ,video.publish for direct posting after TikTok's audit

client_key = input("TikTok Client key: ").strip()
client_secret = getpass.getpass("TikTok Client secret (hidden): ").strip()
state = secrets.token_urlsafe(16)
url = "https://www.tiktok.com/v2/auth/authorize/?" + urllib.parse.urlencode({
    "client_key": client_key, "scope": SCOPES, "response_type": "code",
    "redirect_uri": REDIRECT_URI, "state": state})
print("\n1. Open this link in a browser where you are signed in to the IEA Kenya TikTok account:\n")
print(url)
print("\n2. Approve. The browser then opens the Kenya Debt Counter site; copy the FULL address from the address bar.")
landed = input("\n3. Paste that address here: ").strip()
q = urllib.parse.parse_qs(urllib.parse.urlparse(landed).query)
if q.get("state", [""])[0] != state:
    raise SystemExit("The address does not belong to this sign-in (state mismatch). Run the script again.")
if "code" not in q:
    raise SystemExit(f"No code in the address: {q.get('error_description') or q.get('error') or landed}")
body = urllib.parse.urlencode({"client_key": client_key, "client_secret": client_secret, "code": q["code"][0],
                               "grant_type": "authorization_code", "redirect_uri": REDIRECT_URI}).encode()
req = urllib.request.Request("https://open.tiktokapis.com/v2/oauth/token/", data=body,
                             headers={"Content-Type": "application/x-www-form-urlencoded"})
with urllib.request.urlopen(req, timeout=30) as r:
    tok = json.load(r)
if "refresh_token" not in tok:
    raise SystemExit(f"TikTok refused: {tok}")
print("\nDone. Granted scopes:", tok.get("scope"))
print("Save this as the GitHub secret TIKTOK_REFRESH_TOKEN (Settings -> Secrets and variables -> Actions):\n")
print(tok["refresh_token"])
print(f"\nIt is valid for about {int(tok.get('refresh_expires_in', 0)) // 86400} days; the workflow keeps it fresh.")
