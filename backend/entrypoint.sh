#!/bin/sh
set -e

if [ "$1" = "app.reports.lambda_handler.handler" ]; then
    exec python -m app.reports.lambda_handler
fi

exec "$@"
