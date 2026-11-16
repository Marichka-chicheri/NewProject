"""Run a .sql file in Athena, then print and save the result with its cost figures.

    uv run part2/athena.py part2/sql/03_turnover.sql --source lab8.payments
    uv run part2/athena.py part2/sql/03_turnover.sql --source lab8.payments_parquet --tag parquet

${BUCKET} and ${SOURCE} in the file are replaced before the query is sent.
Each run writes results/<name>[-tag].csv and appends one line to results/stats.csv
(query, data scanned, engine time), the numbers the report compares.
"""

import argparse
import csv
import os
import pathlib
import time

import boto3

BUCKET = os.environ.get("LAB8_BUCKET", "lab8-payments-274394226432")
REGION = os.environ.get("AWS_REGION", "us-east-1")
RESULTS = pathlib.Path(__file__).parent / "results"

athena = boto3.client("athena", region_name=REGION)


def run(sql: str) -> tuple[str, dict]:
    qid = athena.start_query_execution(
        QueryString=sql,
        ResultConfiguration={"OutputLocation": f"s3://{BUCKET}/athena-results/"},
        QueryExecutionContext={"Database": "lab8"},
    )["QueryExecutionId"]
    while True:
        ex = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]
        state = ex["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(1)
    if state != "SUCCEEDED":
        raise SystemExit(f"{state}: {ex['Status'].get('StateChangeReason')}")
    return qid, ex["Statistics"]


def rows(qid: str) -> list[list[str]]:
    out = []
    for page in athena.get_paginator("get_query_results").paginate(QueryExecutionId=qid):
        for r in page["ResultSet"]["Rows"]:
            out.append([c.get("VarCharValue", "") for c in r["Data"]])
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("sql_file")
    p.add_argument("--source", default="lab8.payments", help="table/view for ${SOURCE}")
    p.add_argument("--tag", default="", help="suffix for the result file, e.g. parquet")
    a = p.parse_args()

    path = pathlib.Path(a.sql_file)
    sql = path.read_text(encoding="utf-8").replace("${BUCKET}", BUCKET).replace("${SOURCE}", a.source)
    qid, st = run(sql)

    scanned_mb = st.get("DataScannedInBytes", 0) / 1024 / 1024
    engine_s = st.get("EngineExecutionTimeInMillis", 0) / 1000
    print(f"{path.name} [{a.source}]  scanned {scanned_mb:.2f} MB  engine {engine_s:.2f} s  id {qid}")

    RESULTS.mkdir(exist_ok=True)
    name = path.stem + (f"-{a.tag}" if a.tag else "")
    data = rows(qid)
    if data:
        with open(RESULTS / f"{name}.csv", "w", newline="", encoding="utf-8") as f:
            csv.writer(f).writerows(data)
        for r in data[:40]:
            print("  " + " | ".join(r))
    stats = RESULTS / "stats.csv"
    new = not stats.exists()
    with open(stats, "a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["query", "source", "scanned_mb", "engine_s", "query_id"])
        w.writerow([path.stem, a.source, f"{scanned_mb:.2f}", f"{engine_s:.2f}", qid])


if __name__ == "__main__":
    main()
