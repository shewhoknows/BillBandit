export const USERNAME_MIN_LENGTH = 3
export const USERNAME_MAX_LENGTH = 20

const reservedHandles = new Set([
  'admin',
  'billbandit',
  'help',
  'moderator',
  'official',
  'root',
  'security',
  'support',
  'system',
])

export type UsernameHandleResult =
  | { success: true; username: string }
  | { success: false; error: string }

export function normalizeUsernameHandle(raw: string) {
  return raw.trim().replace(/^@/, '').toLowerCase()
}

export function parseUsernameHandle(raw: string): UsernameHandleResult {
  const username = normalizeUsernameHandle(raw)

  if (username.length < USERNAME_MIN_LENGTH || username.length > USERNAME_MAX_LENGTH) {
    return {
      success: false,
      error: `Username must be ${USERNAME_MIN_LENGTH}-${USERNAME_MAX_LENGTH} characters.`,
    }
  }
  if (!/^[a-z]/.test(username)) {
    return { success: false, error: 'Username must start with a letter.' }
  }
  if (!/^[a-z0-9_]+$/.test(username)) {
    return {
      success: false,
      error: 'Use only lowercase letters, numbers, and underscores.',
    }
  }
  if (username.endsWith('_')) {
    return { success: false, error: 'Username cannot end with an underscore.' }
  }
  if (reservedHandles.has(username)) {
    return { success: false, error: 'That username is reserved.' }
  }

  return { success: true, username }
}
