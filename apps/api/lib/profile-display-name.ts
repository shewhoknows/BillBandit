import { REVIEW_FRIEND_IDS } from './review-account'

export type ProfileDisplayNameInput = {
  id?: string
  username?: string | null
  preferredName?: string | null
  name?: string | null
}

/** Use one public name rule on every friend and shared-group surface. */
export function profileDisplayName(
  profile: ProfileDisplayNameInput,
  fallback = 'Member'
): string {
  const isReviewFriend = REVIEW_FRIEND_IDS.some((id) => id === profile.id)
  const candidates = isReviewFriend
    ? [profile.preferredName, profile.name, profile.username]
    : [profile.username, profile.preferredName, profile.name]
  for (const candidate of candidates) {
    const value = candidate?.trim()
    if (value && value.toLowerCase() !== 'you') return value
  }

  const safeFallback = fallback.trim()
  return safeFallback && safeFallback.toLowerCase() !== 'you' ? safeFallback : 'Member'
}
