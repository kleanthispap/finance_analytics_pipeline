-- Accounts receivable aging: outstanding sales invoices bucketed by days
-- overdue, as at the current date.
--
-- Scope: ACCREC only. Supplier bills (ACCPAY) are a payables question and
-- belong in a separate model - mixing them nets receivables against
-- payables and answers nothing.
--
-- DRAFT invoices are excluded: they are not yet committed and cannot be
-- overdue. They remain in fact_invoice_lines with their status flag for
-- pipeline reporting.
--
-- Outstanding value is derived from invoice header amount_due rather than
-- summing line amounts, because amount_due already accounts for partial
-- payments and credits. Line amounts do not.

{{ config(materialized='table') }}

with invoices as (

    select
        invoice_id,
        invoice_number,
        contact_id,
        invoice_date,
        due_date,
        invoice_status,
        total,
        amount_paid,
        amount_credited,
        amount_due

    from {{ ref('stg_invoices') }}
    where invoice_type = 'ACCREC'
      and invoice_status != 'DRAFT'
      and amount_due > 0

),

aged as (

    select
        *,
        date_diff(current_date(), due_date, day) as days_overdue

    from invoices

)

select
    a.invoice_id,
    a.invoice_number,
    a.contact_id as contact_key,
    c.contact_name,

    a.invoice_date,
    a.due_date      as date_key,
    a.invoice_status,
    a.days_overdue,

    case
        when a.days_overdue <= 0  then '1. Not yet due'
        when a.days_overdue <= 30 then '2. 1-30 days'
        when a.days_overdue <= 60 then '3. 31-60 days'
        when a.days_overdue <= 90 then '4. 61-90 days'
        else                           '5. 90+ days'
    end as aging_bucket,

    a.days_overdue > 0 as is_overdue,

    a.total,
    a.amount_paid,
    a.amount_credited,
    a.amount_due

from aged a
left join {{ ref('stg_contacts') }} c
    on a.contact_id = c.contact_id