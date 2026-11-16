-- The answers about scale: events, unique payments, exact duplicates,
-- and the share of events that arrived more than an hour late.
WITH distinct_events AS (
    SELECT DISTINCT * FROM lab8.payment_events
)
SELECT
    (SELECT count(*) FROM lab8.payment_events)                AS events_raw,
    count(*)                                                  AS events_distinct,
    (SELECT count(*) FROM lab8.payment_events) - count(*)     AS exact_duplicates,
    count(DISTINCT invoiceId)                                 AS unique_invoices,
    count_if(date_diff('second',
                       from_iso8601_timestamp(modifiedDate),
                       from_iso8601_timestamp(receivedAt)) > 3600) AS late_over_1h,
    round(100.0 * count_if(date_diff('second',
                       from_iso8601_timestamp(modifiedDate),
                       from_iso8601_timestamp(receivedAt)) > 3600) / count(*), 4) AS late_over_1h_pct
FROM distinct_events
