import json
import requests

with open("tokens.json") as f:
    t = json.load(f)

tenant = next(
    c for c in t["connections"] if c["tenantName"] == "Demo Company (Global)"
)
print(f"Using tenant: {tenant['tenantName']} ({tenant['tenantId']})\n")

headers = {
    "Authorization": f"Bearer {t['access_token']}",
    "Xero-tenant-id": tenant["tenantId"],
    "Accept": "application/json",
}

for endpoint in ["Invoices", "Contacts", "BankTransactions", "Accounts"]:
    r = requests.get(
        f"https://api.xero.com/api.xro/2.0/{endpoint}", headers=headers, timeout=30
    )
    if r.status_code != 200:
        print(f"{endpoint}: {r.status_code} — {r.text[:200]}")
        continue
    data = r.json()
    key = next(k for k in data if k not in ("Id", "Status", "ProviderName", "DateTimeUTC"))
    print(f"{endpoint}: {len(data.get(key, []))} records")