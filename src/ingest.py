"""Extract Xero accounting data and land raw JSON in BigQuery.

Design: records are landed unmodified, one JSON payload per row, with
ingestion metadata. All parsing, filtering and normalisation happens in dbt.
"""

import base64
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
from dotenv import load_dotenv
from google.cloud import bigquery

PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")

CLIENT_ID = os.getenv("XERO_CLIENT_ID")
CLIENT_SECRET = os.getenv("XERO_CLIENT_SECRET")
GCP_PROJECT = os.getenv("GCP_PROJECT_ID")
BQ_DATASET = os.getenv("BQ_DATASET_RAW", "xero_raw")

TOKEN_PATH = PROJECT_ROOT / "tokens.json"
TOKEN_URL = "https://identity.xero.com/connect/token"
BASE = "https://api.xero.com/api.xro/2.0"
TENANT_NAME = "Demo Company (Global)"

PAGE_SIZE = 100
THROTTLE_SEC = 1.05          # Xero allows 60 calls/minute per tenant
DETAIL_THROTTLE_SEC = 1.05

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("ingest")

# Endpoints landed as-is. `paginated` reflects Xero's behaviour: not every
# endpoint supports the page parameter.
ENDPOINTS = {
    "invoices":          {"path": "Invoices",         "key": "Invoices",         "paginated": True},
    "contacts":          {"path": "Contacts",         "key": "Contacts",         "paginated": True},
    "accounts":          {"path": "Accounts",         "key": "Accounts",         "paginated": False},
    "payments":          {"path": "Payments",         "key": "Payments",         "paginated": True},
    "bank_transactions": {"path": "BankTransactions", "key": "BankTransactions", "paginated": True},
    "credit_notes":      {"path": "CreditNotes",      "key": "CreditNotes",      "paginated": True},
    "items":             {"path": "Items",            "key": "Items",            "paginated": False},
}

# Natural key per entity, used as the raw-layer record identifier.
RECORD_ID = {
    "invoices":          "InvoiceID",
    "contacts":          "ContactID",
    "accounts":          "AccountID",
    "payments":          "PaymentID",
    "bank_transactions": "BankTransactionID",
    "credit_notes":      "CreditNoteID",
    "items":             "ItemID",
    "invoice_details":   "InvoiceID",
}


class XeroClient:
    def __init__(self):
        self.tokens = self._load()
        self.tenant_id = self._resolve_tenant()

    def _load(self):
        if not TOKEN_PATH.exists():
            sys.exit("tokens.json not found — run `python src/auth.py` first.")
        with open(TOKEN_PATH) as f:
            return json.load(f)

    def _save(self):
        with open(TOKEN_PATH, "w") as f:
            json.dump(self.tokens, f, indent=2)

    def _resolve_tenant(self):
        try:
            t = next(c for c in self.tokens["connections"]
                     if c["tenantName"] == TENANT_NAME)
        except StopIteration:
            names = [c["tenantName"] for c in self.tokens["connections"]]
            sys.exit(f"Tenant '{TENANT_NAME}' not connected. Available: {names}")
        return t["tenantId"]

    def refresh(self):
        """Xero rotates refresh tokens — the new one must be persisted."""
        basic = base64.b64encode(f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
        r = requests.post(
            TOKEN_URL,
            headers={"Authorization": f"Basic {basic}",
                     "Content-Type": "application/x-www-form-urlencoded"},
            data={"grant_type": "refresh_token",
                  "refresh_token": self.tokens["refresh_token"]},
            timeout=30,
        )
        r.raise_for_status()
        new = r.json()
        self.tokens.update({
            "access_token": new["access_token"],
            "refresh_token": new["refresh_token"],
            "expires_in": new["expires_in"],
        })
        self._save()
        log.info("Access token refreshed")

    def get(self, path, _retried=False, **params):
        headers = {
            "Authorization": f"Bearer {self.tokens['access_token']}",
            "Xero-tenant-id": self.tenant_id,
            "Accept": "application/json",
        }
        r = requests.get(f"{BASE}/{path}", headers=headers, params=params, timeout=30)

        # Xero signals a missing scope as 401, same as an expired token.
        if r.status_code == 401 and not _retried:
            self.refresh()
            return self.get(path, _retried=True, **params)

        if r.status_code == 429:
            wait = int(r.headers.get("Retry-After", 60)) + 1
            log.warning("Rate limited — sleeping %ss", wait)
            time.sleep(wait)
            return self.get(path, _retried=_retried, **params)

        r.raise_for_status()
        return r.json()

    def get_all(self, path, key, paginated):
        """Fetch every record, following pagination where supported."""
        if not paginated:
            time.sleep(THROTTLE_SEC)
            return self.get(path).get(key, [])

        out, page = [], 1
        while True:
            batch = self.get(path, page=page).get(key, [])
            out.extend(batch)
            if len(batch) < PAGE_SIZE:
                break
            page += 1
            time.sleep(THROTTLE_SEC)
        return out


def wrap(records, entity, run_id):
    """Wrap each record as a raw-layer row: identity + payload + metadata."""
    now = datetime.now(timezone.utc).isoformat()
    id_field = RECORD_ID[entity]
    return [
        {
            "record_id": rec.get(id_field),
            "source_entity": entity,
            "ingested_at": now,
            "ingestion_run_id": run_id,
            "payload": rec,
        }
        for rec in records
    ]


RAW_SCHEMA = [
    bigquery.SchemaField("record_id", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("source_entity", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("ingested_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("ingestion_run_id", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("payload", "JSON", mode="REQUIRED"),
]


def load_to_bq(client, rows, entity):
    """Truncate-and-load. Appropriate here because the Demo Company
    regenerates and volumes are small; an incremental strategy would
    need a reliable UpdatedDateUTC, which this source does not provide."""
    table_id = f"{GCP_PROJECT}.{BQ_DATASET}.raw_{entity}"
    job_config = bigquery.LoadJobConfig(
        schema=RAW_SCHEMA,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
    )
    data = "\n".join(json.dumps(r) for r in rows).encode()
    from io import BytesIO
    job = client.load_table_from_file(BytesIO(data), table_id, job_config=job_config)
    job.result()
    log.info("  loaded %d rows -> %s", len(rows), table_id)


def main():
    missing = [k for k, v in {
        "XERO_CLIENT_ID": CLIENT_ID,
        "XERO_CLIENT_SECRET": CLIENT_SECRET,
        "GCP_PROJECT_ID": GCP_PROJECT,
    }.items() if not v]
    if missing:
        sys.exit(f"Missing in .env: {', '.join(missing)}")

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log.info("Ingestion run %s", run_id)

    xero = XeroClient()
    bq = bigquery.Client(project=GCP_PROJECT)

    invoice_ids = []

    for entity, cfg in ENDPOINTS.items():
        log.info("Extracting %s", entity)
        records = xero.get_all(cfg["path"], cfg["key"], cfg["paginated"])
        log.info("  %d records", len(records))

        if entity == "invoices":
            invoice_ids = [r["InvoiceID"] for r in records]

        if records:
            load_to_bq(bq, wrap(records, entity, run_id), entity)

    # Invoice line items are absent from the list response and require
    # one detail call per invoice.
    log.info("Extracting invoice_details (%d calls)", len(invoice_ids))
    details = []
    for n, inv_id in enumerate(invoice_ids, 1):
        details.append(xero.get(f"Invoices/{inv_id}")["Invoices"][0])
        if n % 20 == 0 or n == len(invoice_ids):
            log.info("  %d/%d", n, len(invoice_ids))
        time.sleep(DETAIL_THROTTLE_SEC)

    if details:
        load_to_bq(bq, wrap(details, "invoice_details", run_id), "invoice_details")

    log.info("Run %s complete", run_id)


if __name__ == "__main__":
    main()