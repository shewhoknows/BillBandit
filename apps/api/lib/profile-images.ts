import { prisma } from './prisma'
import { MOBILE_PROFILE_AVATAR_PREFIX, mobileProfileAvatarImage, parseMobileProfileAvatar } from './profile-avatar'

/** Avatar image names for the given accounts. Unknown or retired values are dropped. */
export async function loadProfileImages(accountIds: string[]): Promise<Record<string, string>> {
  const ids = [...new Set(accountIds)].filter(Boolean)
  if (ids.length === 0) return {}
  const profiles = await prisma.user.findMany({
    where: { id: { in: ids }, deletedAt: null },
    select: { id: true, image: true },
  })
  const images: Record<string, string> = {}
  for (const { id, image } of profiles) {
    if (!image?.startsWith(MOBILE_PROFILE_AVATAR_PREFIX)) continue
    const avatar = parseMobileProfileAvatar(image.slice(MOBILE_PROFILE_AVATAR_PREFIX.length))
    if (avatar) images[id] = mobileProfileAvatarImage(avatar)
  }
  return images
}
