export type ProfileDisplayNameInput = {
  username?: string | null
  preferredName?: string | null
  name?: string | null
}

/** Use one public name rule on every friend and shared-group surface. */
export function profileDisplayName(
  profile: ProfileDisplayNameInput,
  fallback = 'Member'
): string {
  for (const candidate of [profile.username, profile.preferredName, profile.name]) {
    const value = candidate?.trim()
    if (value && value.toLowerCase() !== 'you') return value
  }

  const safeFallback = fallback.trim()
  return safeFallback && safeFallback.toLowerCase() !== 'you' ? safeFallback : 'Member'
}
