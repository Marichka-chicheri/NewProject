import { useState } from 'react'
import { addDays } from 'date-fns'
import { LogOutIcon, PlusIcon } from 'lucide-react'
import { Link } from 'react-router'

import { DateNavigation, ViewSwitcher } from '@/components/calendar-toolbar'
import { DeleteMeetingDialog } from '@/components/delete-meeting-dialog'
import { MeetingDetailsDialog } from '@/components/meeting-details-dialog'
import { MeetingFormDialog } from '@/components/meeting-form-dialog'
import { MeetingsView } from '@/components/meetings-view'
import { Button } from '@/components/ui/button'
import { useMeetings } from '@/hooks/queries'
import type { Meeting } from '@/lib/api'
import { useAuth } from '@/lib/auth'
import { STEP_DAYS, visibleDays, type ViewMode } from '@/lib/calendar'
import { formatRange } from '@/lib/format'

export function HomePage() {
  const { user, signOut } = useAuth()
  const meetings = useMeetings()
  const [mode, setMode] = useState<ViewMode>('list')
  const [anchor, setAnchor] = useState(() => new Date())
  const days = visibleDays(mode, anchor)
  const [formOpen, setFormOpen] = useState(false)
  // Kept after the form closes so the dialog doesn't flip to "Add meeting" while fading out.
  const [meetingToEdit, setMeetingToEdit] = useState<Meeting | null>(null)
  const [newMeetingStart, setNewMeetingStart] = useState<Date | null>(null)
  const [detailsOpen, setDetailsOpen] = useState(false)
  const [viewedId, setViewedId] = useState<string | null>(null)
  const [meetingToDelete, setMeetingToDelete] = useState<Meeting | null>(null)

  // Look the meeting up in the list so the details stay fresh after an edit.
  const viewedMeeting = meetings.data?.find((m) => m.id === viewedId) ?? null

  const openCreate = (start: Date | null = null) => {
    setMeetingToEdit(null)
    setNewMeetingStart(start)
    setFormOpen(true)
  }
  const openEdit = (meeting: Meeting) => {
    setDetailsOpen(false)
    setMeetingToEdit(meeting)
    setFormOpen(true)
  }
  const openDetails = (meeting: Meeting) => {
    setViewedId(meeting.id)
    setDetailsOpen(true)
  }
  const openDelete = (meeting: Meeting) => {
    setDetailsOpen(false)
    setMeetingToDelete(meeting)
  }

  const pickDay = (day: Date) => {
    setAnchor(day)
    setMode('day')
  }

  return (
    <div className="flex h-svh flex-col">
      {/* One compact bar, so the calendar gets the rest of the screen. */}
      <header className="flex flex-wrap items-center gap-x-4 gap-y-2 px-3 py-2.5 md:px-5">
        <h1 className="order-1 text-3xl leading-none">Meetings</h1>
        <div className="order-3 w-full md:order-2 md:w-auto md:flex-1">
          <DateNavigation
            rangeLabel={formatRange(mode, days)}
            onPrev={() => setAnchor((d) => addDays(d, -STEP_DAYS[mode]))}
            onNext={() => setAnchor((d) => addDays(d, STEP_DAYS[mode]))}
            onToday={() => setAnchor(new Date())}
          />
        </div>
        <div className="order-2 ml-auto flex items-center gap-2 md:order-3">
          <ViewSwitcher mode={mode} onModeChange={setMode} />
          <Button onClick={() => openCreate()} aria-label="Add meeting" className="max-sm:px-3">
            <PlusIcon />
            <span className="max-sm:hidden">Add meeting</span>
          </Button>
          {user && (
            <div className="flex items-center gap-2">
              <span className="text-sm font-medium text-foreground max-sm:hidden">
                {user.email}
              </span>
              <Link
                to="/profile"
                className="flex size-8 items-center justify-center rounded-full bg-secondary text-sm font-semibold text-secondary-foreground transition-colors hover:bg-secondary/80 focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:outline-none"
                aria-label="Profile"
                title={`${user.name} · ${user.email}\nEdit profile`}
              >
                {user.name.charAt(0).toUpperCase()}
              </Link>
              <Button
                variant="ghost"
                size="sm"
                aria-label="Sign out"
                title="Sign out"
                onClick={signOut}
                className="gap-1.5"
              >
                <LogOutIcon className="size-4" />
                <span className="max-sm:hidden">Sign out</span>
              </Button>
            </div>
          )}
        </div>
      </header>
      <div className="hairline" />

      <main className="min-h-0 flex-1 p-2 md:p-3">
        <MeetingsView
          mode={mode}
          days={days}
          onPickDay={pickDay}
          onAdd={() => openCreate()}
          onCreateAt={openCreate}
          onOpen={openDetails}
          onEdit={openEdit}
          onDelete={openDelete}
        />
      </main>

      <MeetingFormDialog
        open={formOpen}
        onOpenChange={setFormOpen}
        meeting={meetingToEdit}
        initialStart={newMeetingStart}
      />
      <MeetingDetailsDialog
        meeting={viewedMeeting}
        open={detailsOpen}
        onOpenChange={setDetailsOpen}
        onEdit={openEdit}
        onDelete={openDelete}
      />
      <DeleteMeetingDialog meeting={meetingToDelete} onClose={() => setMeetingToDelete(null)} />
    </div>
  )
}
