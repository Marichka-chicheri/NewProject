-- Query 7: write the deduplicated payments into Parquet, partitioned by dt,
-- under curated/ (CTAS). The partition column must be the last one in the SELECT.
CREATE TABLE lab8.payments_parquet
WITH (
    format            = 'PARQUET',
    write_compression = 'SNAPPY',
    external_location = 's3://${BUCKET}/curated/payments/',
    partitioned_by    = ARRAY['dt']
) AS
SELECT
    invoiceId, status, failureReason, amount, finalAmount, ccy, reference,
    createdDate, modifiedDate, receivedAt,
    merchantId, merchantName, mcc, customerId, paymentMethod, device,
    dt
FROM lab8.payments
