import { useEffect } from 'react'
import { useNavigate, useLocation } from 'react-router'
import { hasAuthParams } from 'react-oidc-context'
import { Loader2Icon, AlertCircleIcon, LogInIcon } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { useAuth, authConfigured } from '@/lib/auth'

export function LoginPage() {
  const { isAuthenticated, isLoading, signIn, oidc } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()

  const hasParams = typeof window !== 'undefined' && hasAuthParams()

  useEffect(() => {
    if (isAuthenticated) {
      const from = (location.state as { from?: string } | null)?.from ?? '/home'
      navigate(from, { replace: true })
      return
    }

    if (!authConfigured || isLoading || hasParams) {
      return
    }

    // Call signinRedirect as soon as page loads
    signIn().catch((err) => {
      console.error('signinRedirect error:', err)
    })
  }, [isAuthenticated, isLoading, hasParams, signIn, navigate, location.state])

  if (!authConfigured) {
    return (
      <div className="flex min-h-svh items-center justify-center p-4">
        <Card className="max-w-md">
          <CardHeader>
            <CardTitle className="text-xl">Authentication not configured</CardTitle>
            <CardDescription>
              Cognito credentials have not been set up in .env yet.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <p className="text-sm text-muted-foreground">
              Run <code className="bg-muted px-1.5 py-0.5 rounded font-mono">make deploy-auth</code> to deploy the Cognito user pool and update .env.
            </p>
          </CardContent>
        </Card>
      </div>
    )
  }

  if (oidc?.error) {
    return (
      <div className="flex min-h-svh items-center justify-center p-4">
        <Card className="max-w-md">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-destructive">
              <AlertCircleIcon className="size-5" />
              Sign-in Error
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <Alert variant="destructive">
              <AlertTitle>Authentication Failed</AlertTitle>
              <AlertDescription>{oidc.error.message}</AlertDescription>
            </Alert>
            <Button onClick={() => signIn()} className="w-full gap-2">
              <LogInIcon className="size-4" />
              Try again
            </Button>
          </CardContent>
        </Card>
      </div>
    )
  }

  return (
    <div className="flex min-h-svh items-center justify-center p-4">
      <Card className="max-w-md w-full text-center">
        <CardHeader>
          <CardTitle className="text-xl">
            {hasParams ? 'Completing sign in...' : 'Redirecting to sign in...'}
          </CardTitle>
          <CardDescription>
            {hasParams
              ? 'Verifying your credentials and signing you in.'
              : 'Taking you to the secure Cognito sign-in page.'}
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col items-center justify-center py-6 gap-4">
          <Loader2Icon className="size-8 animate-spin text-primary" />
          <Button variant="outline" size="sm" onClick={() => signIn()}>
            Click here if you are not redirected automatically
          </Button>
        </CardContent>
      </Card>
    </div>
  )
}
