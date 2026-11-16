-- Athena over the data that came through Kinesis -> Firehose -> S3 (table lab8.stream_events).
-- Per payment method: events, unique payments, failure share of outcomes, and the
-- end-to-end delay from entering the stream (sentAt) to landing in S3 is bounded by the
-- Firehose buffer (60 s); here we show the event-time span that was replayed.
WITH e AS (
    SELECT DISTINCT * FROM lab8.stream_events WHERE dt = '2026-11-07'
)
SELECT
    paymentmethod,
    count(*)                                                     AS events,
    count(DISTINCT invoiceid)                                    AS payments,
    count_if(status IN ('success', 'failure'))                   AS outcomes,
    round(100.0 * count_if(status = 'failure')
          / nullif(count_if(status IN ('success', 'failure')), 0), 2) AS failure_pct,
    min(modifieddate)                                            AS first_event_time,
    max(modifieddate)                                            AS last_event_time,
    min(sentat)                                                  AS first_sent,
    max(sentat)                                                  AS last_sent
FROM e
GROUP BY paymentmethod
ORDER BY events DESC
