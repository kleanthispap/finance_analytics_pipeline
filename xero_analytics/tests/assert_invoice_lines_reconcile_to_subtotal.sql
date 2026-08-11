-- Asserts that normalised net line amounts sum to the invoice header
-- SubTotal, for both Exclusive and Inclusive tax bases.
--
-- This test fails against raw LineAmount values (19 of 68 source invoices
-- state amounts inclusive of tax) and passes against the normalised
-- line_amount_net produced in stg_invoice_lines. It encodes the finding
-- rather than restating it: if the normalisation logic regresses, this
-- catches it immediately.
--
-- Tolerance of 0.02 accommodates rounding across multi-line invoices.
--
-- A singular test passes when it returns zero rows.

with line_totals as (

    select
        invoice_id,
        sum(line_amount_net) as sum_net

    from {{ ref('stg_invoice_lines') }}
    group by invoice_id

)

select
    i.invoice_id,
    i.invoice_number,
    i.line_amount_types,
    l.sum_net,
    i.subtotal,
    abs(l.sum_net - i.subtotal) as variance

from line_totals l
inner join {{ ref('stg_invoices') }} i using (invoice_id)
where abs(l.sum_net - i.subtotal) > 0.02