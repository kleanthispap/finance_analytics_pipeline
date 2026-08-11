-- Invoice line fact. Grain: one row per line item on a retained invoice.
--
-- IMPORTANT: invoice_type must be filtered in any measure. ACCREC (sales)
-- and ACCPAY (bills) are economically opposite; summing across both nets
-- receivables against payables and is almost never what is wanted.
--
-- Header-level values (subtotal, total, amount_paid) are deliberately NOT
-- carried here. Up to 3 lines share an invoice, so a header value repeated
-- at line grain would triple when summed. Header measures belong in a
-- separate invoice-grain model.

{{ config(materialized='table') }}

select
    l.invoice_line_id as invoice_line_key,
    l.invoice_id,
    l.contact_id      as contact_key,
    l.account_id      as account_key,
    l.invoice_date    as date_key,

    l.invoice_number,
    l.invoice_type,
    l.invoice_status,
    l.line_amount_types,
    l.description,
    l.tax_type,
    l.item_code,

    l.quantity,
    l.unit_amount,
    l.line_amount_net,
    l.line_amount_gross,
    l.tax_amount

from {{ ref('stg_invoice_lines') }} l