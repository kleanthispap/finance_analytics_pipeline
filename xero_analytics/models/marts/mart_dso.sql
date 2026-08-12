-- Days sales outstanding: time from invoice date to payment date for
-- settled sales invoices.
--
-- Scope: ACCREC only, and only invoices with a matching payment. Bills
-- (ACCPAY) measure days payable outstanding, a different question.
--
-- Payment-to-invoice is 1:1 after the soft-delete filter applied in
-- staging, so this join cannot fan out. That property is enforced by a
-- uniqueness test on fact_payments.invoice_id.

{{ config(materialized='table') }}

select
    i.invoice_id,
    i.invoice_number,
    i.contact_id as contact_key,
    c.contact_name,

    i.invoice_date,
    i.due_date,
    p.payment_date as date_key,

    date_diff(p.payment_date, i.invoice_date, day) as days_to_pay,
    date_diff(p.payment_date, i.due_date, day)     as days_vs_terms,
    date_diff(i.due_date, i.invoice_date, day)     as payment_terms_days,

    p.payment_date > i.due_date as paid_late,

    i.total,
    p.amount as amount_paid

from {{ ref('stg_invoices') }} i
inner join {{ ref('stg_payments') }} p using (invoice_id)
left join {{ ref('stg_contacts') }} c using (contact_id)
where i.invoice_type = 'ACCREC'