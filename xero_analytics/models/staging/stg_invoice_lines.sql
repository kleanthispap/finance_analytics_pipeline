-- Invoice line items, unnested from raw invoice detail payloads.
--
-- Tax normalisation (validated against all 68 source invoices in
-- notebooks/01_api_exploration.ipynb):
--
--   Exclusive invoices  -> LineAmount excludes tax, reconciles to SubTotal
--   Inclusive invoices  -> LineAmount includes tax, reconciles to Total
--
-- Summing LineAmount across both without normalising adds tax-exclusive and
-- tax-inclusive figures together, overstating net value on the 19 Inclusive
-- invoices in the source. The case expressions below produce a consistent
-- net and gross measure; the reconciliation is asserted by a singular test.
--
-- Inherits the invoice-level status filter via the join to stg_invoices,
-- dropping 13 of 77 lines.

with details as (

    select payload
    from {{ source('xero_raw', 'raw_invoice_details') }}

),

exploded as (

    select
        json_value(payload, '$.InvoiceID')       as invoice_id,
        json_value(payload, '$.LineAmountTypes') as line_amount_types,
        line
    from details,
    unnest(json_query_array(payload, '$.LineItems')) as line

),

parsed as (

    select
        json_value(line, '$.LineItemID')   as invoice_line_id,
        invoice_id,
        line_amount_types,
        json_value(line, '$.AccountID')    as account_id,
        json_value(line, '$.AccountCode')  as account_code,
        json_value(line, '$.Description')  as description,
        json_value(line, '$.TaxType')      as tax_type,
        json_value(line, '$.ItemCode')     as item_code,

        cast(json_value(line, '$.Quantity')   as numeric) as quantity,
        cast(json_value(line, '$.UnitAmount') as numeric) as unit_amount,
        cast(json_value(line, '$.LineAmount') as numeric) as line_amount_raw,
        cast(json_value(line, '$.TaxAmount')  as numeric) as tax_amount

    from exploded

),

normalised as (

    select
        * except (line_amount_raw),

        case line_amount_types
            when 'Exclusive' then line_amount_raw
            when 'Inclusive' then line_amount_raw - tax_amount
        end as line_amount_net,

        case line_amount_types
            when 'Exclusive' then line_amount_raw + tax_amount
            when 'Inclusive' then line_amount_raw
        end as line_amount_gross

    from parsed

)

select
    n.*,
    i.invoice_number,
    i.invoice_type,
    i.invoice_status,
    i.contact_id,
    i.invoice_date

from normalised n
inner join {{ ref('stg_invoices') }} i using (invoice_id)