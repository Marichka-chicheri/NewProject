import { zodResolver } from '@hookform/resolvers/zod'
import { useState } from 'react'
import { Controller, useForm } from 'react-hook-form'
import { Link, useLocation, useNavigate } from 'react-router'
import { z } from 'zod'

import { AuthLayout, GoogleButton, OrDivider, PasswordInput } from '@/components/auth-layout'
import { Button } from '@/components/ui/button'
import { Field, FieldError, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { useConfirmSignup, useGoogleLogin, useResendCode, useSignup } from '@/lib/auth'

const signupSchema = z
  .object({
    name: z.string().trim().min(1, 'Enter your name').max(100),
    email: z.email('Enter a valid email'),
    password: z.string().min(8, 'Use at least 8 characters'),
    confirmPassword: z.string(),
  })
  .refine((v) => v.password === v.confirmPassword, {
    message: 'Passwords do not match',
    path: ['confirmPassword'],
  })

type SignupValues = z.infer<typeof signupSchema>

type LocationState = {
  confirmEmail?: string
} | null

export function SignupPage() {
  const navigate = useNavigate()
  const locationState = useLocation().state as LocationState
  const signup = useSignup()
  const confirmSignup = useConfirmSignup()
  const resendCode = useResendCode()
  const googleLogin = useGoogleLogin()

  const [confirmingEmail, setConfirmingEmail] = useState<string | null>(
    locationState?.confirmEmail ?? null,
  )
  const [code, setCode] = useState('')
  const [confirmError, setConfirmError] = useState<string | null>(null)
  const [resendNotice, setResendNotice] = useState<string | null>(null)

  const pending = signup.isPending || googleLogin.isPending || confirmSignup.isPending

  const form = useForm<SignupValues>({
    resolver: zodResolver(signupSchema),
    defaultValues: { name: '', email: '', password: '', confirmPassword: '' },
  })

  const onError = (error: Error) => form.setError('root', { message: error.message })

  const onSubmit = form.handleSubmit(({ name, email, password }) =>
    signup.mutate(
      { name: name.trim(), email, password },
      {
        onSuccess: (data) => {
          if (data.needsConfirmation) {
            setConfirmingEmail(email)
          } else {
            navigate('/home', { replace: true })
          }
        },
        onError,
      },
    ),
  )

  const handleConfirm = (e: React.FormEvent) => {
    e.preventDefault()
    if (!confirmingEmail || !code.trim()) return
    setConfirmError(null)
    confirmSignup.mutate(
      { email: confirmingEmail, code: code.trim() },
      {
        onSuccess: () => navigate('/home', { replace: true }),
        onError: (err) => setConfirmError(err.message),
      },
    )
  }

  const handleResend = () => {
    if (!confirmingEmail) return
    setResendNotice(null)
    setConfirmError(null)
    resendCode.mutate(confirmingEmail, {
      onSuccess: () => setResendNotice('A new code has been sent to your email.'),
      onError: (err) => setConfirmError(err.message),
    })
  }

  if (confirmingEmail) {
    return (
      <AuthLayout
        title="Check your email"
        subtitle={`We sent a verification code to ${confirmingEmail}.`}
        footer={
          <button
            type="button"
            onClick={() => setConfirmingEmail(null)}
            className="font-semibold text-hover underline-offset-4 hover:underline"
          >
            Back to sign up
          </button>
        }
      >
        <form onSubmit={handleConfirm} noValidate>
          <FieldGroup className="gap-4">
            <Field>
              <FieldLabel htmlFor="confirm-code">Verification code</FieldLabel>
              <Input
                id="confirm-code"
                placeholder="123456"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                autoFocus
              />
            </Field>
            {confirmError && <FieldError>{confirmError}</FieldError>}
            {resendNotice && <p className="text-sm text-muted-foreground">{resendNotice}</p>}
            <Button
              type="submit"
              className="w-full"
              disabled={!code.trim() || confirmSignup.isPending}
            >
              {confirmSignup.isPending ? 'Verifying...' : 'Verify & Continue'}
            </Button>
            <div className="text-center">
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={handleResend}
                disabled={resendCode.isPending}
              >
                {resendCode.isPending ? 'Sending...' : 'Resend code'}
              </Button>
            </div>
          </FieldGroup>
        </form>
      </AuthLayout>
    )
  }

  return (
    <AuthLayout
      title="Create account"
      subtitle="Plan meetings with your team."
      footer={
        <>
          Already have an account?{' '}
          <Link to="/login" className="font-semibold text-hover underline-offset-4 hover:underline">
            Sign in
          </Link>
        </>
      }
    >
      <GoogleButton
        disabled={pending}
        pending={googleLogin.isPending}
        onClick={() =>
          googleLogin.mutate(undefined, {
            onSuccess: () => navigate('/home', { replace: true }),
            onError,
          })
        }
      >
        Sign up with Google
      </GoogleButton>
      <OrDivider />
      <form onSubmit={onSubmit} noValidate>
        <FieldGroup className="gap-4 short:gap-3">
          <Controller
            name="name"
            control={form.control}
            render={({ field, fieldState }) => (
              <Field data-invalid={fieldState.invalid}>
                <FieldLabel htmlFor="signup-name">Name</FieldLabel>
                <Input
                  id="signup-name"
                  autoComplete="name"
                  autoFocus
                  aria-invalid={fieldState.invalid}
                  {...field}
                />
                <FieldError errors={[fieldState.error]} />
              </Field>
            )}
          />
          <Controller
            name="email"
            control={form.control}
            render={({ field, fieldState }) => (
              <Field data-invalid={fieldState.invalid}>
                <FieldLabel htmlFor="signup-email">Email</FieldLabel>
                <Input
                  id="signup-email"
                  type="email"
                  autoComplete="email"
                  aria-invalid={fieldState.invalid}
                  {...field}
                />
                <FieldError errors={[fieldState.error]} />
              </Field>
            )}
          />
          {/* Side by side on wider screens so the whole form fits without scrolling. */}
          <div className="grid gap-4 sm:grid-cols-2 short:gap-3">
            <Controller
              name="password"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="signup-password">Password</FieldLabel>
                  <PasswordInput
                    id="signup-password"
                    autoComplete="new-password"
                    placeholder="At least 8 characters"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
            <Controller
              name="confirmPassword"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="signup-confirm">Confirm</FieldLabel>
                  <PasswordInput
                    id="signup-confirm"
                    autoComplete="new-password"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
          </div>
          {form.formState.errors.root && (
            <FieldError>{form.formState.errors.root.message}</FieldError>
          )}
          <Button type="submit" className="mt-1 w-full" disabled={pending}>
            {signup.isPending ? 'Creating account...' : 'Create account'}
          </Button>
        </FieldGroup>
      </form>
    </AuthLayout>
  )
}
