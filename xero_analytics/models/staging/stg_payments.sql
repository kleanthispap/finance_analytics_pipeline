-- Payments, parsed from raw JSON.
--
-- Filters to AUTHORISED (17 of 51 records are DELETED).
--
-- The Xero API returns soft-deleted payments alongside live ones. In this
-- source, 16 invoices carried a matching AUTHORISED/DELETED pair with the
-- same date, amount and type — so an unfiltered sum overstates cash received
-- by roughly 45%, with no visible error. Filtering to AUTHORISED reduces
-- reconciliation mismatches against invoice AmountPaid from 17 to zero, and
-- collapses payment -> invoice from 1:many to 1:1.
--
-- See notebooks/01_api_exploration.ipynb §6.2.

with source as (

    select payload
    from {{ source('xero_raw', 'raw_payments') }}

),

parsed as (

    select
        json_value(payload, '$.PaymentID')          as payment_id,
        json_value(payload, '$.Invoice.InvoiceID')  as invoice_id,
        json_value(payload, '$.Account.AccountID')  as account_id,
        json_value(payload, '$.PaymentType')        as payment_type,
        json_value(payload, '$.Status')             as payment_status,
        json_value(payload, '$.BatchPaymentID')     as batch_payment_id,

        cast(json_value(payload, '$.IsReconciled') as bool)    as is_reconciled,
        cast(json_value(payload, '$.Amount')       as numeric) as amount,
        cast(json_value(payload, '$.BankAmount')   as numeric) as bank_amount,

        date(timestamp_millis(cast(
            regexp_extract(json_value(payload, '$.Date'), r'\((\d+)') as int64
        )))                                                    as payment_date

    from source

)

select *
from parsed
where payment_status = 'AUTHORISED'