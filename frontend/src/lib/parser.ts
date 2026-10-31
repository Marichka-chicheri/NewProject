import { format } from 'date-fns'

import type { ParseResult } from '@/lib/api'
import { getIdToken } from '@/lib/auth'

// Function URL of the agenda parser (make deploy-ai). Only parses: saving goes through the API.
const PARSER_URL = (import.meta.env.VITE_PARSER_URL ?? '').replace(/\/+$/, '')

export const parserEnabled = PARSER_URL !== ''

/** Same limit as the parser checks before it calls the model. */
export const MAX_PASTE_CHARS = 10_000

export type ParseErrorKind =
  'too_long' | 'no_agenda' | 'busy' | 'timeout' | 'auth' | 'network' | 'failed' | 'cancelled'

const MESSAGES: Record<ParseErrorKind, string> = {
  too_long: `The text is too long. Paste at most ${MAX_PASTE_CHARS.toLocaleString('en')} characters.`,
  no_agenda: 'Could not find an agenda in this text.',
  busy: 'The parser is busy right now. Wait a few seconds and try again.',
  timeout: 'The parser took too long to answer. Try again, or a shorter text.',
  auth: 'Your session has expired. Sign in again to use the parser.',
  network: 'Could not reach the parser. Check your connection and try again.',
  failed: 'The parser failed. Try again in a moment.',
  cancelled: 'Cancelled.',
}

export class ParseError extends Error {
  readonly kind: ParseErrorKind

  constructor(kind: ParseErrorKind, message?: string) {
    super(message ?? MESSAGES[kind])
    this.kind = kind
  }
}

function kindFor(status: number): ParseErrorKind {
  if (status === 401) return 'auth'
  if (status === 413) return 'too_long'
  if (status === 422) return 'no_agenda'
  if (status === 429) return 'busy'
  if (status === 504) return 'timeout'
  return 'failed'
}

/** Sends pasted text to the parser; `signal` lets the user cancel the wait. */
export async function parseAgenda(text: string, signal: AbortSignal): Promise<ParseResult> {
  if (text.length > MAX_PASTE_CHARS) throw new ParseError('too_long')
  const token = await getIdToken()
  let response: Response
  try {
    response = await fetch(PARSER_URL, {
      method: 'POST',
      signal,
      headers: {
        'Content-Type': 'application/json',
        ...(token && { Authorization: `Bearer ${token}` }),
      },
      // The user's "Monday" is in the user's time zone, not in the function's (UTC).
      body: JSON.stringify({
        text,
        today: format(new Date(), 'yyyy-MM-dd'),
        tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      }),
    })
  } catch (error) {
    if (signal.aborted) throw new ParseError('cancelled')
    throw new ParseError('network', error instanceof Error ? undefined : String(error))
  }
  if (!response.ok) throw new ParseError(kindFor(response.status))
  const result = (await response.json()) as ParseResult
  const { items, action_items } = result.agenda
  if (items.length === 0 && action_items.length === 0) throw new ParseError('no_agenda')
  return result
}
