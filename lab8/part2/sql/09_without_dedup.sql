-- What breaks without deduplication: count and sum UAH successes straight from the raw
-- events and compare with the deduplicated view. Also: how many payments have two
-- *different* events with the same modifiedDate (a tie that row_number breaks arbitrarily).
WITH raw AS (
    SELECT count_if(status = 'success')                AS successes,
           sum(IF(status = 'success', finalAmount, 0)) AS amount_minor
    FROM lab8.payment_events WHERE ccy = 980
), dedup AS (
    SELECT count_if(status = 'success')                AS successes,
           sum(IF(status = 'success', finalAmount, 0)) AS amount_minor
    FROM lab8.payments WHERE ccy = 980
), ties AS (
    SELECT count(*) AS invoices_with_tie FROM (
        SELECT invoiceId
        FROM (SELECT DISTINCT * FROM lab8.payment_events)
        GROUP BY invoiceId
        HAVING count(DISTINCT modifiedDate) < count(*)
    )
)
SELECT raw.successes                     AS raw_successes,
       dedup.successes                   AS dedup_successes,
       raw.successes - dedup.successes   AS extra_successes,
       CAST((raw.amount_minor - dedup.amount_minor) / 100.0 AS decimal(18, 2)) AS extra_uah,
       ties.invoices_with_tie
FROM raw, dedup, ties
