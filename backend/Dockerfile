FROM python:3.14-slim AS base

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PORT=8000

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --no-install-project

COPY . .
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
EXPOSE 8000
# Listens on $PORT: 8000 by default (Docker Compose, Lambda Web Adapter's AWS_LWA_PORT), 8080 on
# Cloud Run, which sets PORT itself.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]

# AWS Lambda only (`docker build --target lambda`, infra/deploy-backend.sh): the Lambda Web
# Adapter extension turns Lambda invocations into HTTP requests to the unchanged uvicorn app.
FROM base AS lambda
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter

# Default target: a plain container that serves HTTP on $PORT, with no Lambda layer
# (Docker Compose, Cloud Run).
FROM base AS app
