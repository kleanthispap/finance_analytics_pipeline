import os
import secrets
import base64
import json
import webbrowser
from urllib.parse import urlencode

import requests
from flask import Flask, request
from dotenv import load_dotenv

load_dotenv()

CLIENT_ID = os.getenv("XERO_CLIENT_ID")
CLIENT_SECRET = os.getenv("XERO_CLIENT_SECRET")
REDIRECT_URI = os.getenv("XERO_REDIRECT_URI")

AUTH_URL = "https://login.xero.com/identity/connect/authorize"
TOKEN_URL = "https://identity.xero.com/connect/token"
CONNECTIONS_URL = "https://api.xero.com/connections"

SCOPES = [
    "offline_access",
    "accounting.contacts.read",
    "accounting.invoices.read",
    "accounting.banktransactions.read",
    "accounting.settings.read",
    "accounting.payments.read",
]

STATE = secrets.token_urlsafe(16)
app = Flask(__name__)


def build_auth_url():
    params = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "scope": " ".join(SCOPES),
        "state": STATE,
    }
    return f"{AUTH_URL}?{urlencode(params)}"


def exchange_code_for_tokens(code):
    basic = base64.b64encode(f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
    resp = requests.post(
        TOKEN_URL,
        headers={
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": REDIRECT_URI,
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def get_tenant_id(access_token):
    resp = requests.get(
        CONNECTIONS_URL,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


@app.route("/callback")
def callback():
    if request.args.get("state") != STATE:
        return "State mismatch — aborting.", 400

    error = request.args.get("error")
    if error:
        return f"Authorization failed: {error}", 400

    tokens = exchange_code_for_tokens(request.args.get("code"))
    connections = get_tenant_id(tokens["access_token"])

    payload = {
        "access_token": tokens["access_token"],
        "refresh_token": tokens["refresh_token"],
        "expires_in": tokens["expires_in"],
        "connections": connections,
    }

    with open("tokens.json", "w") as f:
        json.dump(payload, f, indent=2)

    names = [c.get("tenantName") for c in connections]
    print("\nConnected tenants:", names)
    print("Tokens written to tokens.json")

    shutdown = request.environ.get("werkzeug.server.shutdown")
    if shutdown:
        shutdown()

    return f"Success. Connected to: {', '.join(names)}. You can close this tab."


if __name__ == "__main__":
    if not all([CLIENT_ID, CLIENT_SECRET, REDIRECT_URI]):
        raise SystemExit("Missing credentials — check your .env file.")
    url = build_auth_url()
    print(f"Opening browser for authorization...\n{url}\n")
    webbrowser.open(url)
    app.run(port=5000)