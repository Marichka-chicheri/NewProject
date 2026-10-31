-include .env

COMPOSE := docker compose
DB_PORT ?= 5432
LOCAL_DATABASE_URL := $(subst @db:5432,@localhost:$(DB_PORT),$(DATABASE_URL))
s ?=

.DEFAULT_GOAL := help
.PHONY: help env build up down restart logs ps migrate migration seed psql test lint format \
	dev-backend dev-frontend install clean deploy deploy-backend deploy-frontend destroy-backend destroy-frontend add-domain remove-domain infra-lint \
	infra-init infra-fmt infra-validate infra-plan infra-output update-lambdas report-now llm-hello llm-models parse

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(firstword $(MAKEFILE_LIST)) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "Created .env")

build: env ## Build all images
	$(COMPOSE) build

up: env ## Build and start the whole stack
	$(COMPOSE) up -d --build
	@echo "App:      http://localhost:3000"
	@echo "API docs: http://localhost:8000/api/docs"

down: ## Stop the stack
	$(COMPOSE) down

restart: down up ## Restart the stack

logs: ## Follow logs (optionally: make logs s=backend)
	$(COMPOSE) logs -f $(s)

ps: ## Show running services
	$(COMPOSE) ps

migrate: ## Apply database migrations
	$(COMPOSE) exec backend alembic upgrade head

migration: ## Generate a migration: make migration m="add something" (db must be up)
	@test -n "$(m)" || (echo 'Usage: make migration m="message"' && exit 1)
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run alembic revision --autogenerate -m "$(m)"

seed: ## Insert sample participants and meetings
	$(COMPOSE) exec backend python -m app.seed

psql: ## Open psql in the db container
	$(COMPOSE) exec db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

test: ## Run backend tests (against the <db>_test database)
	$(COMPOSE) exec backend pytest -v

lint: ## Lint backend and frontend
	cd backend && uv run ruff check . && uv run ruff format --check .
	cd frontend && npm run lint && npx prettier --check .

format: ## Format backend and frontend
	cd backend && uv run ruff check --fix . && uv run ruff format .
	cd frontend && npm run format

install: ## Install local dev dependencies (uv + npm)
	cd backend && uv sync
	cd frontend && npm install

dev-backend: env ## Run backend locally with reload (db runs in Docker)
	$(COMPOSE) up -d db
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run alembic upgrade head
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run uvicorn app.main:app --reload --port 8000

dev-frontend: ## Run Vite dev server on http://localhost:5173 (proxies /api to :8000)
	cd frontend && npm run dev

clean: ## Stop the stack and delete the database volume
	$(COMPOSE) down -v

# AWS credentials and settings come from .env; export them only to the recipes below.
AWS_ENV := MSYS_NO_PATHCONV=1 AWS_ACCESS_KEY_ID="$(AWS_ACCESS_KEY_ID)" AWS_SECRET_ACCESS_KEY="$(AWS_SECRET_ACCESS_KEY)" \
	AWS_SESSION_TOKEN="$(AWS_SESSION_TOKEN)" AWS_REGION="$(AWS_REGION)" \
	PROJECT_NAME="$(or $(PROJECT_NAME),$(APP_NAME))" CORS_ORIGINS_AWS="$(CORS_ORIGINS_AWS)" \
	LAMBDA_MEMORY="$(LAMBDA_MEMORY)" DOMAIN_NAME="$(DOMAIN_NAME)" HOSTED_ZONE_ID="$(HOSTED_ZONE_ID)" \
	COGNITO_USER_POOL_ID="$(COGNITO_USER_POOL_ID)" COGNITO_CLIENT_ID="$(COGNITO_CLIENT_ID)" \
	COGNITO_DOMAIN="$(COGNITO_DOMAIN)" COGNITO_GOOGLE_ENABLED="$(COGNITO_GOOGLE_ENABLED)" \
	PARSER_MODEL="$(or $(PARSER_MODEL),us.amazon.nova-lite-v1:0)"

deploy: deploy-backend deploy-frontend ## Deploy the whole app to AWS (Cognito, reports and the parser: HCP Terraform)

deploy-backend: env ## Deploy backend (Lambda) + database (Aurora Serverless) to AWS, see infra/
	@$(AWS_ENV) ./infra/deploy-backend.sh
	@$(AWS_ENV) ./infra/update-lambdas.sh

deploy-frontend: env ## Deploy frontend to S3 + CloudFront, wired to the Lambda URL (after deploy-backend)
	@$(AWS_ENV) ./infra/deploy-frontend.sh

# Cognito, the reports and the agenda parser are Terraform (infra/*.tf). HCP Terraform applies
# them after a merge; nothing here applies. `terraform login` once, then these only read or plan.
infra-init: ## terraform init: connect to the HCP Terraform workspace
	terraform -chdir=infra init

infra-fmt: ## Format the Terraform files
	terraform -chdir=infra fmt -recursive

infra-validate: ## Check the Terraform syntax, types and references (touches nothing in AWS)
	terraform -chdir=infra validate

infra-plan: ## Plan in HCP Terraform (speculative: nothing is applied)
	terraform -chdir=infra plan

infra-output: ## Print the Terraform outputs (user pool, queue URL, parser URL, ...)
	terraform -chdir=infra output

update-lambdas: env ## Point the report builder and agenda parser at the backend's current image
	@$(AWS_ENV) ./infra/update-lambdas.sh

report-now: env ## Request a report on demand: make report-now [WEEK=2026-W39]
	@$(AWS_ENV) bash -c '\
		source infra/common.sh; \
		queue_url="$$(terraform -chdir=infra output -raw report_requests_queue_url 2>/dev/null)"; \
		[ -n "$$queue_url" ] || { echo "Reports not applied yet, or run: terraform login && make infra-init" >&2; exit 1; }; \
		week_val="$(WEEK)"; \
		payload="$$(python3 -c '\''import json, sys; print(json.dumps({"week": sys.argv[1] if sys.argv[1] else None, "source": "cli"}))'\'' "$$week_val")"; \
		aws sqs send-message --queue-url "$$queue_url" --message-body "$$payload"; \
		echo "Sent report request for week: $${week_val:-<previous week>}"'

llm-models: env ## List the Claude model IDs this AWS account can call on Bedrock
	@cd backend && $(AWS_ENV) uv run python -m app.ai.hello --models

llm-hello: env ## First Bedrock call from the laptop: prints the answer, stop_reason and usage
	@cd backend && $(AWS_ENV) uv run python -m app.ai.hello

# The text goes through the environment, so quotes and apostrophes in it survive the shell.
export TEXT
parse: env ## Parse an agenda from the laptop: make parse TEXT="Пн 10:00, синк по прайсингу..."
	@test -n "$$TEXT" || (echo 'Usage: make parse TEXT="..."' && exit 1)
	@cd backend && $(AWS_ENV) uv run python -m app.ai.agenda "$$TEXT"

add-domain: env ## Attach DOMAIN_NAME from .env to the deployed frontend
	@$(AWS_ENV) ./infra/add-domain.sh

remove-domain: env ## Detach the custom domain and delete its certificate
	@$(AWS_ENV) ./infra/remove-domain.sh

destroy-backend: env ## Delete the AWS backend stacks (keeps a final DB snapshot)
	@$(AWS_ENV) ./infra/destroy-backend.sh

destroy-frontend: env ## Delete the S3 bucket, CloudFront distribution and domain certificate
	@$(AWS_ENV) ./infra/destroy-frontend.sh

infra-lint: ## Lint the CloudFormation templates and the Terraform files
	uvx cfn-lint infra/*.yaml
	terraform -chdir=infra fmt -check -recursive
