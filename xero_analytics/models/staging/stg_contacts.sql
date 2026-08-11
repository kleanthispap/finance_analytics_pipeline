-- Contacts. No status filter needed — all 50 are ACTIVE, unlike the
-- transactional entities which carry soft-deleted records.
--
-- Balances.* fields are deliberately excluded: they are API-computed
-- aggregates as of request time, not source facts. Carrying them into a
-- dimension would freeze a point-in-time snapshot that goes stale and can
-- contradict figures derived from invoices and payments. Outstanding
-- balances are calculated in the mart layer instead.
--
-- Note: contact name is NOT unique (49 distinct across 50 rows). All joins
-- and groupings must use contact_id.

with source as (

    select payload
    from {{ source('xero_raw', 'raw_contacts') }}

)

select
    json_value(payload, '$.ContactID')     as contact_id,
    json_value(payload, '$.Name')          as contact_name,
    json_value(payload, '$.EmailAddress')  as email_address,
    json_value(payload, '$.FirstName')     as first_name,
    json_value(payload, '$.LastName')      as last_name,
    json_value(payload, '$.ContactStatus') as contact_status,

    cast(json_value(payload, '$.IsCustomer') as bool) as is_customer,
    cast(json_value(payload, '$.IsSupplier') as bool) as is_supplier

from source