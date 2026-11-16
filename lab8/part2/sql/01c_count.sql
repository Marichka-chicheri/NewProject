-- Sanity check: about three million events in 31 partitions.
SELECT count(*) AS events, count(DISTINCT dt) AS days
FROM lab8.payment_events
