interface ImportMetaEnv {
  readonly VITE_API_URL?: string
  /** Function URL of the agenda parser (make deploy-ai); empty hides Paste an agenda. */
  readonly VITE_PARSER_URL?: string
  readonly COGNITO_USER_POOL_ID?: string
  readonly COGNITO_CLIENT_ID?: string
  readonly COGNITO_DOMAIN?: string
  readonly COGNITO_GOOGLE_ENABLED?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
