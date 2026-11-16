-- Query 2: one row per payment (invoiceId), the event with the latest modifiedDate.
-- Step 1 removes exact duplicates (the webhook was delivered twice).
-- Step 2 ranks the remaining events of each payment, newest first.
-- Dates become real timestamps here, so every later query can use hour(), date_diff() etc.
CREATE OR REPLACE VIEW lab8.payments AS
WITH distinct_events AS (
    SELECT DISTINCT * FROM lab8.payment_events
),
ranked AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY invoiceId
            ORDER BY from_iso8601_timestamp(modifiedDate) DESC
        ) AS rn
    FROM distinct_events
)
SELECT
    invoiceId,
    status,
    failureReason,
    amount,
    finalAmount,
    ccy,
    reference,
    CAST(from_iso8601_timestamp(createdDate)  AS timestamp) AS createdDate,
    CAST(from_iso8601_timestamp(modifiedDate) AS timestamp) AS modifiedDate,
    CAST(from_iso8601_timestamp(receivedAt)   AS timestamp) AS receivedAt,
    merchantId,
    merchantName,
    mcc,
    customerId,
    paymentMethod,
    device,
    dt
FROM ranked
WHERE rn = 1
