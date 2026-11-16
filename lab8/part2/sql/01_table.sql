-- Query 1: the raw table over JSON Lines, one row per webhook event.
-- Dates stay strings here: the OpenX SerDe does not parse "2026-10-01T08:15:22Z"
-- into a timestamp, so the view below converts them once.
CREATE EXTERNAL TABLE IF NOT EXISTS lab8.payment_events (
    invoiceId      string,
    status         string,
    failureReason  string,
    amount         bigint,
    finalAmount    bigint,
    ccy            int,
    reference      string,
    createdDate    string,
    modifiedDate   string,
    receivedAt     string,
    merchantId     string,
    merchantName   string,
    mcc            int,
    customerId     string,
    paymentMethod  string,
    device         string
)
PARTITIONED BY (dt string)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ('ignore.malformed.json' = 'true')
LOCATION 's3://${BUCKET}/payments/'
