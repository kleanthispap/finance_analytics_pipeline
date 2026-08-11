-- Account dimension.
--
-- account_class is the primary categorisation attribute:
-- EXPENSE 29, LIABILITY 15, ASSET 9, REVENUE 3, EQUITY 2.
--
-- is_transacting flags the 17 of 58 accounts actually referenced by an
-- invoice line. BankAccountNumber is excluded at staging - account number
-- data with no analytical purpose.

{{ config(materialized='table') }}

with accounts as (

    select * from {{ ref('stg_accounts') }}

),

transacting as (

    select distinct account_id
    from {{ ref('stg_invoice_lines') }}

)

select
    a.account_id     as account_key,
    a.account_code,
    a.account_name,
    a.account_type,
    a.account_class,
    a.reporting_code,
    a.reporting_code_name,
    a.tax_type,
    a.description,
    t.account_id is not null as is_transacting

from accounts a
left join transacting t using (account_id)