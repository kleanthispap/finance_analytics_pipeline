-- Aging bucket dimension.
--
-- Exists so that buckets with no invoices still appear in reporting. The
-- fact table only contains buckets that occurred (3 of 5 on the demo
-- source); a report driven by the fact alone silently omits the severe
-- buckets, which understates what an aging report is for.
--
-- Standard dimensional practice: the dimension holds all possible values,
-- the fact holds what happened.

{{ config(materialized='table') }}

select *
from unnest([
    struct('1. Not yet due' as aging_bucket, 1 as sort_order, false as is_overdue),
    struct('2. 1-30 days',                   2,               true),
    struct('3. 31-60 days',                  3,               true),
    struct('4. 61-90 days',                  4,               true),
    struct('5. 90+ days',                    5,               true)
])