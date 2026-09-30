import { useState, type FormEvent, useEffect } from 'react'
import { ArrowLeftIcon, LogOutIcon } from 'lucide-react'
import { Link } from 'react-router'
import { toast } from 'sonner'

import { PasswordInput } from '@/components/auth-layout'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Field, FieldError, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import {
  useAuth,
  useChangeEmail,
  useChangePassword,
  useConfirmEmail,
  useResendEmailCode,
  useUpdateName,
} from '@/lib/auth'

export function ProfilePage() {
  const { user, signOut } = useAuth()
  const isGoogle = user?.provider === 'google'

  return (
    <div className="min-h-svh bg-[radial-gradient(ellipse_at_top,#fef4f6,transparent_60%)] px-4 py-8">
      <div className="mx-auto flex w-full max-w-lg flex-col gap-6">
        {/* Top bar with back arrow */}
        <div className="flex items-center gap-3">
          <Button
            asChild
            variant="ghost"
            size="icon"
            className="rounded-full"
            aria-label="Back to meetings"
          >
            <Link to="/home">
              <ArrowLeftIcon className="size-5" />
            </Link>
          </Button>
          <h1 className="text-3xl leading-none">Profile</h1>
        </div>

        {/* User Identity Card */}
        {user && (
          <div className="flex items-center gap-4 rounded-[24px] bg-card p-5">
            <div className="flex size-14 shrink-0 items-center justify-center rounded-full bg-secondary text-xl font-bold text-secondary-foreground">
              {user.name.charAt(0).toUpperCase()}
            </div>
            <div className="min-w-0 flex-1">
              <h2 className="truncate text-xl font-semibold">{user.name}</h2>
              <p className="truncate text-sm text-muted-foreground">{user.email}</p>
            </div>
          </div>
        )}

        {/* Google Notice */}
        {isGoogle ? (
          <Alert>
            <AlertDescription>
              Your account is signed in with Google. Your name, email, and password are managed
              directly through your Google account.
            </AlertDescription>
          </Alert>
        ) : (
          <div className="flex flex-col gap-5">
            <NameCard currentName={user?.name ?? ''} />
            <EmailCard currentEmail={user?.email ?? ''} />
            <PasswordCard />
          </div>
        )}

        {/* Sign out button at bottom */}
        <div className="pt-2">
          <Button
            variant="outline"
            className="w-full gap-2 border-destructive/30 text-destructive hover:bg-destructive/10"
            onClick={signOut}
          >
            <LogOutIcon className="size-4" />
            Sign out
          </Button>
        </div>
      </div>
    </div>
  )
}

function NameCard({ currentName }: { currentName: string }) {
  const [name, setName] = useState(currentName)
  const updateName = useUpdateName()

  useEffect(() => {
    setName(currentName)
  }, [currentName])

  const isChanged = name.trim() !== '' && name.trim() !== currentName

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault()
    if (!isChanged) return
    updateName.mutate(name.trim(), {
      onSuccess: () => toast.success('Name updated successfully'),
      onError: (err) => toast.error(err.message),
    })
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Display Name</CardTitle>
        <CardDescription>Your name as seen by participants in meetings.</CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <Field>
            <FieldLabel htmlFor="profile-name">Name</FieldLabel>
            <Input
              id="profile-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Your name"
            />
          </Field>
          <div className="flex justify-end">
            <Button type="submit" disabled={!isChanged || updateName.isPending}>
              {updateName.isPending ? 'Saving...' : 'Save name'}
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  )
}

function EmailCard({ currentEmail }: { currentEmail: string }) {
  const [newEmail, setNewEmail] = useState('')
  const [code, setCode] = useState('')
  const [needsConfirmation, setNeedsConfirmation] = useState(false)

  const changeEmail = useChangeEmail()
  const confirmEmail = useConfirmEmail()
  const resendCode = useResendEmailCode()

  const handleStartChange = (e: FormEvent) => {
    e.preventDefault()
    if (!newEmail.trim() || newEmail.trim() === currentEmail) return
    changeEmail.mutate(newEmail.trim(), {
      onSuccess: (data) => {
        if (data.needsConfirmation) {
          setNeedsConfirmation(true)
          toast.success(`Verification code sent to ${newEmail.trim()}`)
        } else {
          toast.success('Email updated')
          setNewEmail('')
        }
      },
      onError: (err) => toast.error(err.message),
    })
  }

  const handleConfirm = (e: FormEvent) => {
    e.preventDefault()
    if (!code.trim()) return
    confirmEmail.mutate(code.trim(), {
      onSuccess: () => {
        toast.success('Email updated successfully')
        setNeedsConfirmation(false)
        setNewEmail('')
        setCode('')
      },
      onError: (err) => toast.error(err.message),
    })
  }

  const handleCancel = () => {
    setNeedsConfirmation(false)
    setCode('')
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Email Address</CardTitle>
        <CardDescription>
          {needsConfirmation
            ? `Enter the code sent to ${newEmail} to complete the change.`
            : `Current email: ${currentEmail}`}
        </CardDescription>
      </CardHeader>
      <CardContent>
        {needsConfirmation ? (
          <form onSubmit={handleConfirm} className="flex flex-col gap-4">
            <Field>
              <FieldLabel htmlFor="verification-code">Verification Code</FieldLabel>
              <Input
                id="verification-code"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="123456"
                autoFocus
              />
            </Field>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="flex gap-2">
                <Button
                  type="button"
                  variant="ghost"
                  onClick={() =>
                    resendCode.mutate(undefined, {
                      onSuccess: () => toast.success('New code sent'),
                      onError: (err) => toast.error(err.message),
                    })
                  }
                  disabled={resendCode.isPending}
                >
                  Send a new code
                </Button>
                <Button type="button" variant="outline" onClick={handleCancel}>
                  Cancel
                </Button>
              </div>
              <Button type="submit" disabled={!code.trim() || confirmEmail.isPending}>
                {confirmEmail.isPending ? 'Verifying...' : 'Verify email'}
              </Button>
            </div>
          </form>
        ) : (
          <form onSubmit={handleStartChange} className="flex flex-col gap-4">
            <Field>
              <FieldLabel htmlFor="profile-email">New email</FieldLabel>
              <Input
                id="profile-email"
                type="email"
                value={newEmail}
                onChange={(e) => setNewEmail(e.target.value)}
                placeholder="new.email@example.com"
              />
            </Field>
            <div className="flex justify-end">
              <Button
                type="submit"
                disabled={
                  !newEmail.trim() || newEmail.trim() === currentEmail || changeEmail.isPending
                }
              >
                {changeEmail.isPending ? 'Sending code...' : 'Change email'}
              </Button>
            </div>
          </form>
        )}
      </CardContent>
    </Card>
  )
}

function PasswordCard() {
  const [currentPassword, setCurrentPassword] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [error, setError] = useState<string | null>(null)

  const changePassword = useChangePassword()

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault()
    setError(null)

    if (newPassword.length < 8) {
      setError('New password must be at least 8 characters')
      return
    }
    if (newPassword !== confirmPassword) {
      setError('Passwords do not match')
      return
    }

    changePassword.mutate(
      { currentPassword, newPassword },
      {
        onSuccess: () => {
          toast.success('Password updated successfully')
          setCurrentPassword('')
          setNewPassword('')
          setConfirmPassword('')
        },
        onError: (err) => setError(err.message),
      },
    )
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Change Password</CardTitle>
        <CardDescription>Must be at least 8 characters long.</CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          {error && (
            <Alert variant="destructive">
              <AlertDescription>{error}</AlertDescription>
            </Alert>
          )}
          <FieldGroup className="gap-3">
            <Field>
              <FieldLabel htmlFor="current-password">Current password</FieldLabel>
              <PasswordInput
                id="current-password"
                value={currentPassword}
                onChange={(e) => setCurrentPassword(e.target.value)}
                autoComplete="current-password"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="new-password">New password</FieldLabel>
              <PasswordInput
                id="new-password"
                value={newPassword}
                onChange={(e) => setNewPassword(e.target.value)}
                autoComplete="new-password"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="confirm-password">Confirm new password</FieldLabel>
              <PasswordInput
                id="confirm-password"
                value={confirmPassword}
                onChange={(e) => setConfirmPassword(e.target.value)}
                autoComplete="new-password"
              />
              {confirmPassword && newPassword !== confirmPassword && (
                <FieldError>Passwords do not match</FieldError>
              )}
            </Field>
          </FieldGroup>
          <div className="flex justify-end">
            <Button
              type="submit"
              disabled={
                !currentPassword || !newPassword || !confirmPassword || changePassword.isPending
              }
            >
              {changePassword.isPending ? 'Updating...' : 'Update password'}
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  )
}
