import json, logging, os, urllib.parse, boto3
from email.message import EmailMessage

logger = logging.getLogger("report-mailer")
logger.setLevel(logging.INFO)
s3_client = boto3.client("s3")
ses_client = boto3.client("sesv2")

def handler(event, context=None):
    if not event.get("Records"):
        return {"status": "ignored"}
    record = event["Records"][0]
    bucket = record["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

    logger.info("report-mailer triggered", extra={"trigger": "s3", "key": key})
    print(f"report-mailer triggered: trigger=s3 key={key}")

    resp = s3_client.get_object(Bucket=bucket, Key=key)
    csv_bytes = resp["Body"].read()

    filename = os.path.basename(key)
    week_name = filename.replace(".csv", "")
    sender = os.environ["SENDER_EMAIL"]
    recipients = [r.strip() for r in os.environ["RECIPIENT_EMAIL"].split(",") if r.strip()]

    msg = EmailMessage()
    msg["Subject"] = f"Weekly Meetings Report: {week_name}"
    msg["From"] = sender
    msg["To"] = ", ".join(recipients)
    msg.set_content(
        f"Hi,\n\nPlease find attached the weekly meetings summary report for {week_name}.\n\n"
        "Best regards,\nMeetings App"
    )
    msg.add_attachment(csv_bytes, maintype="text", subtype="csv", filename=filename)

    ses_client.send_email(
        FromEmailAddress=sender,
        Destination={"ToAddresses": recipients},
        Content={"Raw": {"Data": msg.as_bytes()}},
    )
    logger.info(f"Report {filename} delivered to {recipients}", extra={"trigger": "s3", "key": key})
    return {"status": "delivered", "key": key, "recipients": recipients}
