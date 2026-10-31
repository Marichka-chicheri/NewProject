"""A minimal AWS Lambda runtime loop for the handlers that share the backend's container image
(the image has no Lambda runtime client; the API itself runs through the Lambda Web Adapter).

Same loop as app/reports/lambda_handler.py, reusable: entrypoint.sh starts
`python -m <module>` for a handler, and the module calls serve(handler).
"""

import json
import logging
import os
import urllib.request
from collections.abc import Callable
from typing import Any

log = logging.getLogger("lambda-runtime")

Handler = Callable[[dict[str, Any], Any], Any]


def _post(url: str, payload: Any) -> None:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request):
        pass


def serve(handler: Handler) -> None:
    runtime_api = os.environ.get("AWS_LAMBDA_RUNTIME_API")
    if not runtime_api:
        raise SystemExit("AWS_LAMBDA_RUNTIME_API is not set: this only runs on Lambda")
    base = f"http://{runtime_api}/2018-06-01/runtime/invocation"
    while True:
        # Blocks until the next invocation arrives.
        with urllib.request.urlopen(f"{base}/next") as response:
            request_id = response.headers["Lambda-Runtime-Aws-Request-Id"]
            body = response.read().decode()
        try:
            result = handler(json.loads(body) if body else {}, None)
        except Exception as error:
            log.exception("unhandled error")
            _post(
                f"{base}/{request_id}/error",
                {"errorMessage": str(error), "errorType": type(error).__name__},
            )
        else:
            _post(f"{base}/{request_id}/response", result)
