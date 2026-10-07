import { createContext, useContext } from 'react'
import type { User as OidcUser } from 'oidc-client-ts'
import type { AuthContextProps } from 'react-oidc-context'

export type User = {
  name: string
  email: string
  provider: 'password' | 'google'
}

const env = import.meta.env
export const authConfig = {
  userPoolId: env.COGNITO_USER_POOL_ID ?? '',
  clientId: env.COGNITO_CLIENT_ID ?? '',
  domain: env.COGNITO_DOMAIN ?? '',
  googleEnabled: env.COGNITO_GOOGLE_ENABLED === 'true',
}

export const authConfigured = Boolean(authConfig.userPoolId && authConfig.clientId)

const region = authConfig.userPoolId ? authConfig.userPoolId.split('_')[0] : 'us-east-1'

export const oidcConfig = {
  authority: authConfigured ? `https://cognito-idp.${region}.amazonaws.com/${authConfig.userPoolId}` : '',
  client_id: authConfig.clientId,
  redirect_uri: `${typeof window !== 'undefined' ? window.location.origin : ''}/login`,
  response_type: 'code',
  scope: 'openid email profile',
  onSigninCallback: () => {
    if (typeof window !== 'undefined') {
      window.history.replaceState({}, document.title, window.location.pathname)
    }
  },
}

export function getCognitoLogoutUrl(): string {
  if (typeof window === 'undefined') return ''
  let domain = authConfig.domain
  if (domain && !domain.startsWith('http://') && !domain.startsWith('https://')) {
    domain = `https://${domain}`
  }
  const logoutUri = `${window.location.origin}/login`
  return `${domain}/logout?client_id=${authConfig.clientId}&logout_uri=${logoutUri}`
}

let activeOidcUser: OidcUser | null = null

export function setOidcUser(user: OidcUser | null) {
  activeOidcUser = user
}

export async function getIdToken(): Promise<string | null> {
  return activeOidcUser?.id_token ?? null
}

export type AuthContextValue = {
  user: User | null | undefined
  isAuthenticated: boolean
  isLoading: boolean
  signIn: () => Promise<void>
  signOut: () => Promise<void>
  oidc?: AuthContextProps
}

export const AuthContext = createContext<AuthContextValue | null>(null)

export function useAuth(): AuthContextValue {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth must be used inside <AuthProvider>')
  return value
}
