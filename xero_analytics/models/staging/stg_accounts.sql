-- Chart of accounts. All 58 are ACTIVE; no filter required.
--
-- Class drives the P&L / balance-sheet split and is the primary
-- categorisation attribute for spend and revenue analysis:
--   EXPENSE 29, LIABILITY 15, ASSET 9, REVENUE 3, EQUITY 2
--
-- Note only 17 of 58 accounts are referenced by any invoice line, so this
-- dimension is largely unused rows. BankAccountNumber is excluded — account
-- number data with no analytical purpose.

with source as (

    select payload
    from {{ source('xero_raw', 'raw_accounts') }}

)

select
    json_value(payload, '$.AccountID')         as account_id,
    json_value(payload, '$.Code')              as account_code,
    json_value(payload, '$.Name')              as account_name,
    json_value(payload, '$.Type')              as account_type,
    json_value(payload, '$.Class')             as account_class,
    json_value(payload, '$.Description')       as description,
    json_value(payload, '$.ReportingCode')     as reporting_code,
    json_value(payload, '$.ReportingCodeName') as reporting_code_name,
    json_value(payload, '$.TaxType')           as tax_type,
    json_value(payload, '$.SystemAccount')     as system_account

from source