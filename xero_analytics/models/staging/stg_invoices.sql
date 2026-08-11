-- Invoice headers, parsed from raw JSON.
--
-- Filters VOIDED and DELETED (11 of 68 records). These are cancelled
-- transactions, not events that occurred; retaining them invites accidental
-- inclusion in revenue measures. DRAFT is retained with its status flag —
-- a draft is a pending real transaction, not a cancelled one.

with source as (

    select payload
    from {{ source('xero_raw', 'raw_invoices') }}

),

parsed as (

    select
        json_value(payload, '$.InvoiceID')              as invoice_id,
        json_value(payload, '$.InvoiceNumber')          as invoice_number,
        json_value(payload, '$.Type')                   as invoice_type,
        json_value(payload, '$.Status')                 as invoice_status,
        json_value(payload, '$.LineAmountTypes')        as line_amount_types,
        json_value(payload, '$.Contact.ContactID')      as contact_id,
        json_value(payload, '$.Reference')              as reference,

        -- Xero returns two date representations; the epoch-millis form
        -- (/Date(1786233600000+0000)/) is unusable, so the ISO-8601
        -- *String variants are parsed throughout.
        date(parse_timestamp(
            '%Y-%m-%dT%H:%M:%S', json_value(payload, '$.DateString')
        ))                                              as invoice_date,
        date(parse_timestamp(
            '%Y-%m-%dT%H:%M:%S', json_value(payload, '$.DueDateString')
        ))                                              as due_date,

        cast(json_value(payload, '$.SubTotal')       as numeric) as subtotal,
        cast(json_value(payload, '$.TotalTax')       as numeric) as total_tax,
        cast(json_value(payload, '$.Total')          as numeric) as total,
        cast(json_value(payload, '$.AmountDue')      as numeric) as amount_due,
        cast(json_value(payload, '$.AmountPaid')     as numeric) as amount_paid,
        cast(json_value(payload, '$.AmountCredited') as numeric) as amount_credited

    from source

)

select *
from parsed
where invoice_status not in ('VOIDED', 'DELETED')