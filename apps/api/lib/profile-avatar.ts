export const MOBILE_PROFILE_AVATAR_PREFIX = 'billbandit-avatar:'

export const mobileProfileAvatars = [
  'sunglasses',
  'bucket-hat',
  'bows',
  'messy-tie',
  'headphones',
  'bandana',
  'beanie',
  'flower',
] as const

export type MobileProfileAvatar = (typeof mobileProfileAvatars)[number]

const allowedAvatars = new Set<string>(mobileProfileAvatars)

export function parseMobileProfileAvatar(value: unknown): MobileProfileAvatar | null {
  if (typeof value !== 'string') return null
  const normalized = value.trim().toLowerCase()
  return allowedAvatars.has(normalized) ? (normalized as MobileProfileAvatar) : null
}

export function mobileProfileAvatarImage(avatar: MobileProfileAvatar): string {
  return `${MOBILE_PROFILE_AVATAR_PREFIX}${avatar}`
}
