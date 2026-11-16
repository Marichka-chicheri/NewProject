-- Query 4: share of failed payments per payment method and device, highest first.
-- Denominator: payments that finished (success or failure); a payment whose last
-- event is still "processing" has no outcome yet.
SELECT
    paymentMethod,
    device,
    count(*)                                             AS finished,
    count_if(status = 'failure')                         AS failed,
    round(100.0 * count_if(status = 'failure') / count(*), 2) AS failure_pct
FROM ${SOURCE}
WHERE status IN ('success', 'failure')
GROUP BY paymentMethod, device
ORDER BY failure_pct DESC
