from typing import Annotated

from pydantic import field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://meetings:meetings@localhost:5432/meetings"
    # Lambda serves one request per instance at a time, so it runs with a pool of 1.
    db_pool_size: int = 5
    db_max_overflow: int = 10
    # Cognito user pool and app client whose ID tokens the API accepts (make deploy-auth).
    cognito_user_pool_id: str = ""
    cognito_client_id: str = ""
    # The pool's jwks.json. Set on AWS, where the function has no internet access; locally the
    # keys are downloaded on first use.
    cognito_jwks: str = ""
    # Paste an agenda: the Bedrock model the parser calls (configuration, not code) and the
    # longest text it accepts before calling the model.
    # Amazon Nova until Anthropic models are enabled on the account (Converse API); set
    # anthropic.claude-opus-5-5 to use Claude through the Messages API instead.
    parser_model: str = "us.amazon.nova-lite-v1:0"
    parser_max_chars: int = 10_000
    # Lambda sets AWS_REGION itself; the lab runs everything in us-east-1.
    aws_region: str = "us-east-1"
    cors_origins: Annotated[list[str], NoDecode] = [
        "http://localhost:5173",
        "http://localhost:3000",
    ]

    @field_validator("aws_region", "parser_model", mode="before")
    @classmethod
    def empty_means_default(cls, value: object, info) -> object:
        # make passes unset .env values as empty strings.
        return value or cls.model_fields[info.field_name].default

    @field_validator("cors_origins", mode="before")
    @classmethod
    def split_origins(cls, value: object) -> object:
        if isinstance(value, str):
            return [origin.strip() for origin in value.split(",") if origin.strip()]
        return value


settings = Settings()
