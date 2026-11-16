SELECT count(*) events, count(DISTINCT invoiceid) payments, count(DISTINCT "$path") files FROM lab8.stream_events WHERE dt='2026-11-07'
