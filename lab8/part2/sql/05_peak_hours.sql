-- Query 5: payments per hour of the day (UTC, by createdDate), whole month.
SELECT
    hour(createdDate) AS hour_utc,
    count(*)          AS payments
FROM ${SOURCE}
GROUP BY hour(createdDate)
ORDER BY hour_utc
