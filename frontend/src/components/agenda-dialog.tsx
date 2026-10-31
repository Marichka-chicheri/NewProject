import { useEffect, useRef, useState } from 'react'
import { zodResolver } from '@hookform/resolvers/zod'
import { addMinutes, differenceInMinutes, format } from 'date-fns'
import {
  ClipboardPasteIcon,
  LoaderCircleIcon,
  PlusIcon,
  SparklesIcon,
  Trash2Icon,
  XIcon,
} from 'lucide-react'
import { Controller, useFieldArray, useForm, useWatch, type Control } from 'react-hook-form'
import { toast } from 'sonner'
import { z } from 'zod'

import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Field, FieldError, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { useDeleteAgenda, useSaveAgenda, useUpdateMeeting } from '@/hooks/queries'
import type { Agenda, Meeting, ParsedAgenda, ParseResult } from '@/lib/api'
import { MAX_PASTE_CHARS, ParseError, parseAgenda, parserEnabled } from '@/lib/parser'

// ------------------------------------------------------------------ form model

const minutesPattern = /^\d*$/

const itemSchema = z.object({
  topic: z.string().trim().min(1, 'Topic is required').max(300),
  owner: z.string().trim().max(255),
  minutes: z
    .string()
    .regex(minutesPattern, 'Whole minutes')
    .refine((v) => v === '' || (Number(v) >= 1 && Number(v) <= 480), '1–480 minutes'),
  /** Fields the parser filled and the user has not touched yet. */
  suggested: z.array(z.string()),
})

const actionSchema = z.object({
  task: z.string().trim().min(1, 'Task is required').max(500),
  owner: z.string().trim().max(255),
  due: z.string(),
  suggested: z.array(z.string()),
})

const agendaSchema = z
  .object({
    items: z.array(itemSchema).max(50),
    actionItems: z.array(actionSchema).max(50),
  })
  .refine((v) => v.items.length + v.actionItems.length > 0, {
    message: 'Add at least one agenda item or action item',
    path: ['root'],
  })

type AgendaFormValues = z.input<typeof agendaSchema>

const emptyItem = { topic: '', owner: '', minutes: '', suggested: [] }
const emptyAction = { task: '', owner: '', due: '', suggested: [] }

function filled(fields: Record<string, unknown>): string[] {
  return Object.entries(fields)
    .filter(([, value]) => value !== null && value !== undefined && value !== '')
    .map(([key]) => key)
}

function toFormValues(agenda: Agenda | null): AgendaFormValues {
  if (!agenda) return { items: [{ ...emptyItem }], actionItems: [] }
  return {
    items: agenda.items.map((i) => ({
      topic: i.topic,
      owner: i.owner ?? '',
      minutes: i.minutes?.toString() ?? '',
      suggested: [],
    })),
    actionItems: agenda.action_items.map((a) => ({
      task: a.task,
      owner: a.owner ?? '',
      due: a.due ?? '',
      suggested: [],
    })),
  }
}

/** The parser's answer as form values; every field it filled is marked as suggested. */
function fromParsed(parsed: ParsedAgenda): AgendaFormValues {
  return {
    items: parsed.items.map((i) => ({
      topic: i.topic,
      owner: i.owner ?? '',
      minutes: i.minutes?.toString() ?? '',
      suggested: filled({ topic: i.topic, owner: i.owner, minutes: i.minutes }),
    })),
    actionItems: parsed.action_items.map((a) => ({
      task: a.task,
      owner: a.owner ?? '',
      due: a.due ?? '',
      suggested: filled({ task: a.task, owner: a.owner, due: a.due }),
    })),
  }
}

function toAgenda(values: AgendaFormValues): Agenda {
  return {
    items: values.items.map((i) => ({
      topic: i.topic.trim(),
      owner: i.owner.trim() || null,
      minutes: i.minutes === '' ? null : Number(i.minutes),
    })),
    action_items: values.actionItems.map((a) => ({
      task: a.task.trim(),
      owner: a.owner.trim() || null,
      due: a.due || null,
    })),
  }
}

/** The new start and end when the user applies what the text says about the meeting's time. */
function suggestedTimes(meeting: Meeting, parsed: ParsedAgenda) {
  const oldStart = new Date(meeting.starts_at)
  const parsedStart = parsed.starts_at ? new Date(parsed.starts_at) : null
  const start = parsedStart && !Number.isNaN(parsedStart.getTime()) ? parsedStart : oldStart
  const minutes =
    parsed.duration_minutes ?? differenceInMinutes(new Date(meeting.ends_at), oldStart)
  return { start, end: addMinutes(start, minutes) }
}

// ------------------------------------------------------------------ rows

function SuggestedBadge({ show }: { show: boolean }) {
  if (!show) return null
  return (
    <Badge variant="secondary" className="h-5 px-2 text-[0.7rem] font-semibold">
      <SparklesIcon />
      suggested
    </Badge>
  )
}

const suggestedInput = 'border-primary/60 bg-primary/5'

type RowProps = {
  control: Control<AgendaFormValues>
  index: number
  onRemove: () => void
  /** Clears the "suggested" mark of one field once the user edits it. */
  onTouch: (field: string) => void
}

function ItemRow({ control, index, onRemove, onTouch }: RowProps) {
  const suggested = useWatch({ control, name: `items.${index}.suggested` }) ?? []
  const mark = (field: string) => suggested.includes(field)
  return (
    <li className="grid gap-3 rounded-2xl border p-3 sm:grid-cols-[1fr_10rem_6rem_auto]">
      <Controller
        name={`items.${index}.topic`}
        control={control}
        render={({ field, fieldState }) => (
          <Field data-invalid={fieldState.invalid}>
            <FieldLabel htmlFor={`item-${index}-topic`} className="gap-2">
              Topic <SuggestedBadge show={mark('topic')} />
            </FieldLabel>
            <Input
              id={`item-${index}-topic`}
              aria-invalid={fieldState.invalid}
              className={mark('topic') ? suggestedInput : undefined}
              {...field}
              onChange={(e) => {
                field.onChange(e)
                onTouch('topic')
              }}
            />
            <FieldError errors={[fieldState.error]} />
          </Field>
        )}
      />
      <Controller
        name={`items.${index}.owner`}
        control={control}
        render={({ field, fieldState }) => (
          <Field data-invalid={fieldState.invalid}>
            <FieldLabel htmlFor={`item-${index}-owner`} className="gap-2">
              Owner <SuggestedBadge show={mark('owner')} />
            </FieldLabel>
            <Input
              id={`item-${index}-owner`}
              aria-invalid={fieldState.invalid}
              className={mark('owner') ? suggestedInput : undefined}
              {...field}
              onChange={(e) => {
                field.onChange(e)
                onTouch('owner')
              }}
            />
            <FieldError errors={[fieldState.error]} />
          </Field>
        )}
      />
      <Controller
        name={`items.${index}.minutes`}
        control={control}
        render={({ field, fieldState }) => (
          <Field data-invalid={fieldState.invalid}>
            <FieldLabel htmlFor={`item-${index}-minutes`} className="gap-2">
              Min <SuggestedBadge show={mark('minutes')} />
            </FieldLabel>
            <Input
              id={`item-${index}-minutes`}
              inputMode="numeric"
              aria-invalid={fieldState.invalid}
              className={mark('minutes') ? suggestedInput : undefined}
              {...field}
              onChange={(e) => {
                field.onChange(e)
                onTouch('minutes')
              }}
            />
            <FieldError errors={[fieldState.error]} />
          </Field>
        )}
      />
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="self-start sm:mt-6"
        aria-label={`Remove item ${index + 1}`}
        onClick={onRemove}
      >
        <XIcon />
      </Button>
    </li>
  )
}

function ActionRow({ control, index, onRemove, onTouch }: RowProps) {
  const suggested = useWatch({ control, name: `actionItems.${index}.suggested` }) ?? []
  const mark = (field: string) => suggested.includes(field)
  return (
    <li className="grid gap-3 rounded-2xl border p-3 sm:grid-cols-[1fr_10rem_10rem_auto]">
      <Controller
        name={`actionItems.${index}.task`}
        control={control}
        render={({ field, fieldState }) => (
          <Field data-invalid={fieldState.invalid}>
            <FieldLabel htmlFor={`action-${index}-task`} className="gap-2">
              Task <SuggestedBadge show={mark('task')} />
            </FieldLabel>
            <Input
              id={`action-${index}-task`}
              aria-invalid={fieldState.invalid}
              className={mark('task') ? suggestedInput : undefined}
              {...field}
              onChange={(e) => {
                field.onChange(e)
                onTouch('task')
              }}
            />
            <FieldError errors={[fieldState.error]} />
          </Field>
        )}
      />
      <Controller
        name={`actionItems.${index}.owner`}
        control={control}
        render={({ field, fieldState }) => (
          <Field data-invalid={fieldState.invalid}>
            <FieldLabel htmlFor={`action-${index}-owner`} className="gap-2">
              Owner <SuggestedBadge show={mark('owner')} />
            </FieldLabel>
            <Input
              id={`action-${index}-owner`}
              aria-invalid={fieldState.invalid}
              className={mark('owner') ? suggestedInput : undefined}
              {...field}
              onChange={(e) => {
                field.onChange(e)
                onTouch('owner')
              }}
            />
            <FieldError errors={[fieldState.error]} />
          </Field>
        )}
      />
      <Controller
        name={`actionItems.${index}.due`}
        control={control}
        render={({ field, fieldState }) => (
          <Field data-invalid={fieldState.invalid}>
            <FieldLabel htmlFor={`action-${index}-due`} className="gap-2">
              Due <SuggestedBadge show={mark('due')} />
            </FieldLabel>
            <Input
              id={`action-${index}-due`}
              type="date"
              aria-invalid={fieldState.invalid}
              className={mark('due') ? suggestedInput : undefined}
              {...field}
              onChange={(e) => {
                field.onChange(e)
                onTouch('due')
              }}
            />
            <FieldError errors={[fieldState.error]} />
          </Field>
        )}
      />
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="self-start sm:mt-6"
        aria-label={`Remove action item ${index + 1}`}
        onClick={onRemove}
      >
        <XIcon />
      </Button>
    </li>
  )
}

// ------------------------------------------------------------------ the dialog

type Props = {
  meeting: Meeting | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function AgendaDialog({ meeting, open, onOpenChange }: Props) {
  const saveAgenda = useSaveAgenda()
  const deleteAgenda = useDeleteAgenda()
  const updateMeeting = useUpdateMeeting()
  const form = useForm<AgendaFormValues>({
    resolver: zodResolver(agendaSchema),
    defaultValues: toFormValues(null),
  })
  const items = useFieldArray({ control: form.control, name: 'items' })
  const actionItems = useFieldArray({ control: form.control, name: 'actionItems' })

  const [text, setText] = useState('')
  const [parsing, setParsing] = useState(false)
  const [elapsed, setElapsed] = useState(0)
  const [parseError, setParseError] = useState<ParseError | null>(null)
  // The parser's answer behind the current form; sent with Save as the quality signal.
  const [suggestion, setSuggestion] = useState<(ParseResult & { text: string }) | null>(null)
  const [applyMeeting, setApplyMeeting] = useState(false)
  const abortRef = useRef<AbortController | null>(null)

  useEffect(() => {
    if (!open || !meeting) return
    form.reset(toFormValues(meeting.agenda))
    setText('')
    setParseError(null)
    setSuggestion(null)
    setApplyMeeting(false)
    // Only when the dialog opens (or switches meeting): a refetch of the meeting after a save
    // must not wipe what the user is typing.
  }, [open, meeting?.id])

  // A closed dialog stops waiting for the model.
  useEffect(() => {
    if (!open) abortRef.current?.abort()
  }, [open])

  useEffect(() => {
    if (!parsing) return
    const started = Date.now()
    const timer = setInterval(() => setElapsed(Math.floor((Date.now() - started) / 1000)), 500)
    return () => clearInterval(timer)
  }, [parsing])

  if (!meeting) return null

  const parse = async () => {
    const controller = new AbortController()
    abortRef.current = controller
    setParseError(null)
    setElapsed(0)
    setParsing(true)
    try {
      const result = await parseAgenda(text, controller.signal)
      form.reset(fromParsed(result.agenda))
      setSuggestion({ ...result, text })
      setApplyMeeting(false)
    } catch (error) {
      const parseFailure = error instanceof ParseError ? error : new ParseError('failed')
      if (parseFailure.kind !== 'cancelled') setParseError(parseFailure)
    } finally {
      setParsing(false)
      abortRef.current = null
    }
  }

  const touch = (list: 'items' | 'actionItems', index: number) => (field: string) => {
    const path = `${list}.${index}.suggested` as `items.${number}.suggested`
    const current = form.getValues(path)
    if (current.includes(field)) {
      form.setValue(
        path,
        current.filter((f) => f !== field),
      )
    }
  }

  const parsed = suggestion?.agenda
  const mentionsMeeting = Boolean(
    parsed && (parsed.title || parsed.starts_at || parsed.duration_minutes),
  )
  const times = parsed ? suggestedTimes(meeting, parsed) : null

  const onSubmit = form.handleSubmit(async (values) => {
    try {
      if (applyMeeting && parsed && times) {
        await updateMeeting.mutateAsync({
          id: meeting.id,
          title: parsed.title?.trim() || meeting.title,
          description: meeting.description,
          starts_at: times.start.toISOString(),
          ends_at: times.end.toISOString(),
          place: meeting.place,
          participant_ids: meeting.participants.map((p) => p.id),
        })
      }
      // Saved through the normal API, with its validation. The parser never writes.
      await saveAgenda.mutateAsync({
        id: meeting.id,
        ...toAgenda(values),
        ...(suggestion && {
          ai_suggestion: {
            agenda: suggestion.agenda,
            text: suggestion.text,
            model: suggestion.model,
            prompt_version: suggestion.prompt_version,
          },
        }),
      })
      toast.success('Agenda saved')
      onOpenChange(false)
    } catch (error) {
      form.setError('root', { message: error instanceof Error ? error.message : String(error) })
    }
  })

  const removeAgenda = () =>
    deleteAgenda.mutate(meeting.id, {
      onSuccess: () => {
        toast.success('Agenda removed')
        onOpenChange(false)
      },
      onError: (error) => form.setError('root', { message: error.message }),
    })

  const saving = saveAgenda.isPending || updateMeeting.isPending
  const tooLong = text.length > MAX_PASTE_CHARS

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{meeting.agenda ? 'Edit agenda' : 'Add agenda'}</DialogTitle>
          <DialogDescription>{meeting.title}</DialogDescription>
        </DialogHeader>

        <div className="-mx-6 flex flex-col gap-5 overflow-y-auto px-6 py-1">
          {parserEnabled && (
            <section className="flex flex-col gap-3 rounded-[20px] bg-card p-4">
              <h3 className="flex items-center gap-2 text-lg">
                <ClipboardPasteIcon className="size-4" />
                Paste an agenda
              </h3>
              <Field data-invalid={tooLong}>
                <FieldLabel htmlFor="agenda-paste" className="sr-only">
                  Text with the agenda
                </FieldLabel>
                <Textarea
                  id="agenda-paste"
                  rows={4}
                  value={text}
                  disabled={parsing}
                  aria-invalid={tooLong}
                  placeholder="Paste an email, a chat message or notes, e.g. «Пн 10:00, синк по прайсингу, 45 хв. 1) нові тарифи Pro — Олена, 15 хв…»"
                  onChange={(e) => setText(e.target.value)}
                />
                <p className={`text-xs ${tooLong ? 'text-destructive' : 'text-muted-foreground'}`}>
                  {text.length.toLocaleString('en')} / {MAX_PASTE_CHARS.toLocaleString('en')}{' '}
                  characters · the result replaces the form below, and nothing is saved until you
                  press Save
                </p>
              </Field>

              {parsing ? (
                <div className="flex flex-wrap items-center gap-3" role="status" aria-live="polite">
                  <LoaderCircleIcon className="size-4 animate-spin text-primary" />
                  <span className="text-sm">
                    Reading your text… {elapsed > 0 && `${elapsed} s`}{' '}
                    <span className="text-muted-foreground">(usually 2–8 seconds)</span>
                  </span>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => abortRef.current?.abort()}
                  >
                    Cancel
                  </Button>
                </div>
              ) : (
                <div>
                  <Button type="button" onClick={parse} disabled={text.trim() === '' || tooLong}>
                    <SparklesIcon />
                    Parse
                  </Button>
                </div>
              )}

              {parseError && (
                <Alert variant="destructive">
                  <AlertTitle>{parseError.message}</AlertTitle>
                  <AlertDescription>
                    You can still type the agenda in the form below.
                  </AlertDescription>
                </Alert>
              )}

              {suggestion && !parsing && (
                <p className="text-sm text-muted-foreground">
                  <SparklesIcon className="mr-1 inline size-3.5 text-primary" />
                  Fields marked <em>suggested</em> were filled by the model. Check them before
                  saving; empty fields stay empty.
                </p>
              )}

              {mentionsMeeting && parsed && times && (
                <label className="flex items-start gap-3 rounded-2xl border p-3 text-sm">
                  <input
                    type="checkbox"
                    className="mt-0.5 size-4 accent-primary"
                    checked={applyMeeting}
                    onChange={(e) => setApplyMeeting(e.target.checked)}
                  />
                  <span>
                    Also update the meeting
                    <span className="block text-muted-foreground">
                      {parsed.title && <>Title «{parsed.title}» · </>}
                      {format(times.start, 'EEE d MMM, HH:mm')}–{format(times.end, 'HH:mm')}
                      {parsed.duration_minutes && <> ({parsed.duration_minutes} min)</>}
                    </span>
                  </span>
                </label>
              )}
            </section>
          )}

          <form id="agenda-form" onSubmit={onSubmit} noValidate className="flex flex-col gap-5">
            <section className="flex flex-col gap-3">
              <h3 className="text-lg">Agenda items</h3>
              {items.fields.length === 0 ? (
                <p className="text-sm text-muted-foreground">No items.</p>
              ) : (
                <ol className="flex flex-col gap-3">
                  {items.fields.map((row, index) => (
                    <ItemRow
                      key={row.id}
                      control={form.control}
                      index={index}
                      onRemove={() => items.remove(index)}
                      onTouch={touch('items', index)}
                    />
                  ))}
                </ol>
              )}
              <div>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  onClick={() => items.append({ ...emptyItem })}
                >
                  <PlusIcon />
                  Add item
                </Button>
              </div>
            </section>

            <section className="flex flex-col gap-3">
              <h3 className="text-lg">Action items</h3>
              {actionItems.fields.length === 0 ? (
                <p className="text-sm text-muted-foreground">No action items.</p>
              ) : (
                <ul className="flex flex-col gap-3">
                  {actionItems.fields.map((row, index) => (
                    <ActionRow
                      key={row.id}
                      control={form.control}
                      index={index}
                      onRemove={() => actionItems.remove(index)}
                      onTouch={touch('actionItems', index)}
                    />
                  ))}
                </ul>
              )}
              <div>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  onClick={() => actionItems.append({ ...emptyAction })}
                >
                  <PlusIcon />
                  Add action item
                </Button>
              </div>
            </section>

            {form.formState.errors.root?.message && (
              <FieldError>{form.formState.errors.root.message}</FieldError>
            )}
          </form>
        </div>

        <DialogFooter className="sm:justify-between">
          {meeting.agenda ? (
            <Button
              type="button"
              variant="ghost"
              onClick={removeAgenda}
              disabled={deleteAgenda.isPending}
            >
              <Trash2Icon />
              Remove agenda
            </Button>
          ) : (
            <span />
          )}
          <div className="flex flex-col-reverse gap-2 sm:flex-row">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit" form="agenda-form" disabled={saving || parsing}>
              {saving ? 'Saving...' : 'Save agenda'}
            </Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
