import { useQueryClient } from '@tanstack/react-query'
import { useEffect, type ReactNode } from 'react'
import { AuthProvider as OidcAuthProvider, useAuth as useOidcAuth } from 'react-oidc-context'

import {
  AuthContext,
  authConfig,
  authConfigured,
  getCognitoLogoutUrl,
  oidcConfig,
  setOidcUser,
  type User,
} from '@/lib/auth'

function InnerAuthProvider({ children }: { children: ReactNode }) {
  const oidc = useOidcAuth()
  const queryClient = useQueryClient()

  useEffect(() => {
    setOidcUser(oidc.user ?? null)
  }, [oidc.user])

  const user: User | null | undefined = oidc.isLoading
    ? undefined
    : oidc.user
      ? {
          name:
            (oidc.user.profile.name as string) ||
            (oidc.user.profile.email as string)?.split('@')[0] ||
            'User',
          email: (oidc.user.profile.email as string) || '',
          provider:
            oidc.user.profile.identities ||
            (oidc.user.profile['cognito:username'] as string)?.toLowerCase().startsWith('google_')
              ? 'google'
              : 'password',
        }
      : null

  const signOut = async () => {
    try {
      queryClient.clear()
    } catch {}
    try {
      await oidc.removeUser()
    } catch {}
    try {
      sessionStorage.clear()
      localStorage.clear()
    } catch {}
    setOidcUser(null)
    if (authConfig.domain) {
      window.location.href = getCognitoLogoutUrl()
    } else {
      window.location.href = '/login'
    }
  }

  const signIn = async () => {
    await oidc.signinRedirect()
  }

  return (
    <AuthContext.Provider
      value={{
        user,
        isAuthenticated: oidc.isAuthenticated,
        isLoading: oidc.isLoading,
        signIn,
        signOut,
        oidc,
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

function UnconfiguredAuthProvider({ children }: { children: ReactNode }) {
  return (
    <AuthContext.Provider
      value={{
        user: null,
        isAuthenticated: false,
        isLoading: false,
        signIn: async () => {},
        signOut: async () => {},
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function AuthProvider({ children }: { children: ReactNode }) {
  if (!authConfigured) {
    return <UnconfiguredAuthProvider>{children}</UnconfiguredAuthProvider>
  }

  return (
    <OidcAuthProvider {...oidcConfig}>
      <InnerAuthProvider>{children}</InnerAuthProvider>
    </OidcAuthProvider>
  )
}
