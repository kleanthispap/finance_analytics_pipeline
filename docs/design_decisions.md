# Design decisions

Why the model is shaped the way it is. Each decision is traceable to something
observed in the [source profiling](../notebooks/01_api_exploration.ipynb) rather
than to convention.

---

## Extraction

### Raw JSON is landed unmodified; all parsing happens in dbt

`src/ingest.py` writes one row per API record: the natural key, the untouched
payload as a BigQuery `JSON` column, and ingestion metadata. It does no
flattening, filtering or type casting.

**Why.** Transformation logic in an extraction script is untested and
unversioned in any meaningful sense. Moving it to dbt puts every parsing decision
under version control with assertions attached. It also decouples ingestion from
schema drift — a new field appearing in the Xero response cannot break the load.

The immutability argument matters more here than usual: the Demo Company
regenerates on a rolling date window, so the API cannot be relied on to return
the same data next month. Once landed, the raw layer is a stable record even when
the source has moved on.

### Nothing is filtered at ingestion, including deleted records

The 17 soft-deleted payments are landed alongside the live ones.

**Why.** Filtering is a modelling decision, and modelling decisions belong where
they can be tested and explained. Keeping the deleted records also means the raw
layer can *demonstrate* the finding rather than merely assert it — the doubling
is reproducible from what's in the warehouse.

### Full refresh rather than incremental load

`WRITE_TRUNCATE` on every run.

**Why.** Incremental extraction depends on a reliable modification timestamp.
Xero exposes `UpdatedDateUTC`, but in the Demo Company it returns dates in 2008
while transactions are dated 2026. The field is unusable here. `If-Modified-Since`
is the correct approach against a real organisation and is straightforward to
add, but it cannot be validated against this source, so claiming it works would
be dishonest. At 68 invoices, full refresh costs nothing.

### Pagination and throttling are implemented despite not being needed

Xero paginates at 100 records; the largest entity here is 68. The throttle
targets the 60-calls-per-minute limit, which a 68-call loop only just approaches.

**Why.** Both are correctness requirements, not optimisations. Code that happens
to work because the dataset is small is a latent bug. The pagination loop and the
429 backoff are the parts that would matter first against a real organisation.

---

## Grain

### `fact_invoice_lines` is at line-item grain, not invoice header grain

This required 68 additional API calls, because Xero's list endpoint returns
invoice headers with an empty `LineItems` array.

**Why.** `AccountID` only exists at line level. Without it there is no join to
the chart of accounts, and therefore no spend or revenue categorisation at all —
the model would know an invoice was worth $500 without knowing whether that was
consulting revenue or office supplies.

Note this is *not* justified by data richness: at 1.13 lines per invoice, the
line grain adds almost no rows. The categorisation join is the entire argument.

### Header-level amounts are deliberately absent from the line fact

`subtotal`, `total` and `amount_paid` are not carried into `fact_invoice_lines`.

**Why.** Up to three lines share an invoice. A header value repeated at line
grain triples when summed — the classic fan-out error. Header measures belong in
a separate invoice-grain model, and their absence here is a guardrail rather than
an oversight.

---

## Modelling

### One invoice fact with a type flag, not separate AR and AP facts

`ACCREC` (sales invoices, 27) and `ACCPAY` (supplier bills, 30) share a table,
distinguished by `invoice_type`.

**Why.** They have an identical schema. Splitting would duplicate every staging
model, every test and every downstream reference for no structural gain, and 27
sales invoices does not warrant a dedicated pipeline.

**The cost, stated plainly.** They are economically opposite, so summing across
both nets receivables against payables and is almost never correct. `invoice_type`
must be filtered in every measure. This is a real burden the split design would
have avoided; the trade was made knowingly.

### `VOIDED` and `DELETED` are filtered out; `DRAFT` is kept

11 of 68 invoices are voided or deleted (all on the AP side). Two are drafts.

**Why the asymmetry.** A voided invoice is a transaction that did not happen —
retaining it invites accidental inclusion in revenue, and no measure legitimately
counts it. A draft is a *pending real* transaction: excluding it loses the
ability to report pipeline value, while its status flag prevents it being
mistaken for committed revenue. Different facts about the world deserve different
treatment.

### Payments are filtered to `AUTHORISED`

17 of 51 payment records are soft-deleted duplicates.

**Why.** Covered in the [README](../README.md#1-the-api-returns-soft-deleted-records).
The consequence for the model is that payment-to-invoice becomes 1:1, which the
uniqueness test on `fact_payments.invoice_id` encodes. That test is the finding,
expressed as an invariant.

### Tax is normalised in staging, not in the mart or the BI layer

`line_amount_net` and `line_amount_gross` are computed in
`stg_invoice_lines`.

**Why staging specifically.** Every downstream consumer needs the corrected
values, so computing them once at the earliest point prevents divergent
implementations. Leaving it to the BI layer would mean the warehouse holds a
column (`LineAmount`) that is dangerous to sum — an invitation to a wrong number
in any tool that connects directly.

### `dim_item` was dropped

`ItemCode` is populated on 30 of 77 lines (39%), covering 8 of the 16 items in
`/Items`.

**Why.** A dimension with 61% unattributed facts is worse than no dimension —
it invites breakdowns that silently exclude most of the data. `dim_account` has
100% coverage and serves the same categorisation purpose.

### Contact balance fields are excluded from `dim_contact`

Xero returns `Balances.AccountsReceivable.Outstanding` and similar on 16 of 50
contacts.

**Why.** These are API-computed aggregates as of request time, not source facts.
Storing them in a dimension freezes a point-in-time snapshot that goes stale
immediately and can contradict figures derived from the invoice and payment
facts. Two sources of truth for the same number is worse than the minor
convenience of not computing it. Outstanding balances belong in the mart layer,
derived from the facts.

### `is_transacting` flags on both dimensions

Only 29 of 50 contacts and 17 of 58 accounts appear on any invoice line.

**Why.** The unused rows are legitimate dimension members and dropping them would
be wrong — a contact with no invoices is still a contact. But a dashboard
defaulting to all 58 accounts shows 41 empty rows. The flag lets the consumer
choose, without the model making that choice for them.

### `dim_date` carries an `is_future` flag

11 of 68 invoices are dated after the current date.

**Why.** This is an artifact of the Demo Company generating data on a rolling
window, not a forward-looking pipeline. Any time-series chart without a guard
plots activity that has not occurred. Encoding the guard in the dimension makes
it available to every consumer rather than relying on each one remembering.

---

## Testing

### Two tests encode findings rather than restating structure

Most of the 54 tests are conventional: uniqueness, non-null, referential
integrity, accepted values. Two are different.

**`unique` on `fact_payments.invoice_id`** asserts a 1:1 relationship that only
holds because deleted payments are filtered. It is not a property of the source
data — it is a property of the model being correct.

**`assert_invoice_lines_reconcile_to_subtotal`** fails against raw `LineAmount`
values and passes against the normalised ones.

Both share a quality worth naming: they fail on the unfixed data. A test that
passes regardless of whether the bug is present is documentation, not a test.

### `dbt build` rather than `dbt run` then `dbt test`

CI runs `dbt build`, which interleaves tests with models in dependency order.

**Why.** The reconciliation test runs immediately after `stg_invoice_lines` is
created and *before* `fact_invoice_lines` is built. If tax normalisation
regresses, the fact table is never created rather than being created with wrong
values. Running all models then all tests would produce a fully-populated
warehouse full of incorrect numbers alongside a failing test.

### CI writes to a separate dataset

`xero_analytics_ci`, not `xero_analytics`.

**Why.** CI runs on every push, including from branches. Sharing a dataset with
local development means a CI run can overwrite tables mid-analysis, and a broken
branch can leave the development warehouse in a bad state.

### CI validates transformation, not extraction

The workflow runs `dbt build` against whatever is currently in `xero_raw`. It
does not re-ingest from Xero.

**Why.** Re-ingesting would require the OAuth refresh token as a repository
secret, and would fail whenever that token expired or rotated — producing red
builds that say nothing about the code. The honest scope is that CI tests the
modelling layer. Extraction is exercised manually.

---

## Business marts

### AR aging uses invoice `amount_due`, not summed line amounts

`mart_ar_aging` sources outstanding value from the invoice header rather than
aggregating `line_amount_net`.

**Why.** `amount_due` already nets off partial payments and credit notes. The
line facts know nothing about either — a fully-credited invoice would still show
its full line value. Using the header field means the model agrees with what
Xero itself reports, which is the correct answer.

### Aging buckets beyond 60 days are retained despite being empty

The demo source has nothing older than 60 days overdue, so buckets 4 and 5 never
populate.

**Why.** An aging report without a 90+ bucket is not an aging report. The empty
bucket is itself information — it says nothing is severely overdue. Collapsing
the scale to fit the data would bake a property of this particular dataset into
the model's structure.

### The aging model is not reproducible across days

Aging is computed relative to `current_date()`, so re-running it tomorrow gives
different buckets.

**Why, and the limitation.** That is correct behaviour for an aging report,
which is inherently as-at-today. But it means the model cannot be used for
historical comparison — "what did our aging look like last month" is
unanswerable without a snapshot. A dbt snapshot on the invoice table would
enable that and is the natural extension.

### DSO retains measures that show nothing on this data

No invoice in the source was paid late, so `paid_late` is `false` throughout and
`days_vs_terms` is negative for every row.

**Why keep them.** Removing a column because the current data makes it
uninteresting bakes a dataset property into the model. Payment terms do vary
(10 to 22 days), so `days_vs_terms` is a genuinely distinct measure rather than
a constant offset from `days_to_pay` — it would carry real information against
a live organisation. The limitation is documented in the model description
rather than hidden by deletion.

---

## A note on process

Two of the decisions above exist because profiling happened before modelling.
Neither the soft-deleted payments nor the mixed tax basis announces itself: both
produce output that looks entirely reasonable. The 45% cash overstatement would
have reached a dashboard and stayed there.

The same session also produced a smaller lesson worth recording. A `dbt test` run
reported success while four tests silently did not execute, because a stale parse
cache had dropped them from the manifest. The run said `PASS`; the count was
wrong. Checking the number of tests against the number expected is now part of
the routine — a passing test suite is only evidence about the tests that ran.