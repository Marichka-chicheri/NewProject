-- Query 3: turnover by merchant and currency, successful payments only,
-- in major units (hryvnias, dollars, euros) instead of kopiyky/cents.
SELECT
    merchantName,
    CASE ccy WHEN 980 THEN 'UAH' WHEN 840 THEN 'USD' WHEN 978 THEN 'EUR'
             ELSE CAST(ccy AS varchar) END             AS currency,
    count(*)                                           AS payments,
    CAST(sum(finalAmount) / 100.0 AS decimal(18, 2))   AS turnover
FROM ${SOURCE}
WHERE status = 'success'
GROUP BY merchantName, ccy
ORDER BY currency, turnover DESC
