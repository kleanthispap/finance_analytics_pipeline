-- Date dimension covering the observed transaction range.
--
-- is_future guards against the Demo Company's rolling data generation:
-- 11 of 68 source invoices are dated after the current date, so any
-- time-series measure must filter on this or it plots activity that
-- has not occurred.

{{ config(materialized='table') }}

with bounds as (

    select
        least(min(invoice_date), date '2026-06-01') as start_date,
        greatest(max(due_date),  date '2026-12-31') as end_date
    from {{ ref('stg_invoices') }}

),

spine as (

    select day
    from bounds,
    unnest(generate_date_array(start_date, end_date, interval 1 day)) as day

)

select
    day                                    as date_key,
    extract(year    from day)              as year,
    extract(quarter from day)              as quarter,
    extract(month   from day)              as month,
    format_date('%B', day)                 as month_name,
    format_date('%Y-%m', day)              as year_month,
    extract(week    from day)              as week_of_year,
    extract(dayofweek from day)            as day_of_week,
    format_date('%A', day)                 as day_name,
    extract(dayofweek from day) in (1, 7)  as is_weekend,
    day > current_date()                   as is_future

from spine