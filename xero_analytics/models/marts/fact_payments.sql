-- Payment fact. Grain: one row per authorised payment.
--
-- 1:1 with invoice after the soft-delete filter in staging - enforced by
-- a uniqueness test on invoice_id.
--
-- account_key is retained for completeness but supports no breakdown: all
-- payments in this source hit a single bank account.

{{ config(materialized='table') }}

select
    p.payment_id   as payment_key,
    p.invoice_id,
    p.account_id   as account_key,
    p.payment_date as date_key,

    p.payment_type,
    p.payment_status,
    p.batch_payment_id,
    p.is_reconciled,

    p.amount,
    p.bank_amount,

    i.contact_id   as contact_key,
    i.invoice_type,
    i.invoice_number

from {{ ref('stg_payments') }} p
inner join {{ ref('stg_invoices') }} i using (invoice_id)