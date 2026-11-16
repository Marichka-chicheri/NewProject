-- Way B check: the crawled table answers the same question as the hand-written one.
SELECT status, count(*) AS events, count(failurereason) AS with_reason, max(amount) AS max_amount
FROM lab8_crawler.payments
GROUP BY status
ORDER BY events DESC
