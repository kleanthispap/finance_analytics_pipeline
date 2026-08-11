-- Contact dimension.
--
-- Includes an is_transacting flag: only 29 of 50 contacts appear on any
-- invoice, so dashboards should generally filter on this rather than
-- showing 21 rows with no facts.

{{ config(materialized='table') }}

with contacts as (

    select * from {{ ref('stg_contacts') }}

),

transacting as (

    select distinct contact_id
    from {{ ref('stg_invoices') }}

)

select
    c.contact_id     as contact_key,
    c.contact_name,
    c.email_address,
    c.first_name,
    c.last_name,
    c.is_customer,
    c.is_supplier,
    t.contact_id is not null as is_transacting

from contacts c
left join transacting t using (contact_id)