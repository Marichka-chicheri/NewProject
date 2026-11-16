-- Query 6: events that reached us more than 60 seconds after they happened
-- (processing time receivedAt minus event time modifiedDate), out of all events.
-- Works on events, not payments, so it reads the raw table (exact duplicates removed).
WITH distinct_events AS (
    SELECT DISTINCT * FROM lab8.payment_events
),
delays AS (
    SELECT date_diff('second',
                     from_iso8601_timestamp(modifiedDate),
                     from_iso8601_timestamp(receivedAt)) AS delay_s
    FROM distinct_events
)
SELECT
    count_if(delay_s > 60)                                 AS late_over_60s,
    count(*)                                               AS events,
    round(100.0 * count_if(delay_s > 60) / count(*), 3)    AS late_pct,
    max(delay_s)                                           AS max_delay_s,
    approx_percentile(delay_s, 0.99)                       AS p99_delay_s
FROM delays
