import { ArrowLeftIcon, LogOutIcon, UserIcon } from 'lucide-react'
import { Link } from 'react-router'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { useAuth } from '@/lib/auth'

export function ProfilePage() {
  const { user, signOut } = useAuth()

  if (!user) return null

  return (
    <div className="mx-auto flex min-h-svh max-w-xl flex-col justify-center px-4 py-12">
      <div className="mb-6">
        <Link to="/home" className="inline-flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground">
          <ArrowLeftIcon className="size-4" />
          Back to meetings
        </Link>
      </div>

      <Card>
        <CardHeader>
          <div className="flex items-center gap-3">
            <div className="flex size-12 items-center justify-center rounded-full bg-secondary text-lg font-bold text-secondary-foreground">
              {user.name.charAt(0).toUpperCase()}
            </div>
            <div>
              <CardTitle className="text-xl">{user.name}</CardTitle>
              <CardDescription>{user.email}</CardDescription>
            </div>
          </div>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="rounded-lg border p-3">
            <div className="text-xs text-muted-foreground">Sign-in provider</div>
            <div className="mt-1 font-medium capitalize flex items-center gap-2">
              <UserIcon className="size-4 text-muted-foreground" />
              {user.provider === 'google' ? 'Google Account' : 'Email & Password'}
            </div>
          </div>

          <div className="flex justify-end pt-2">
            <Button variant="destructive" onClick={signOut} className="gap-2">
              <LogOutIcon className="size-4" />
              Sign out
            </Button>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
