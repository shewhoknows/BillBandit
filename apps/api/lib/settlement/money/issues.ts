import { prisma } from '@/lib/prisma'

/** True when the group has unresolved float→minor migration issues (blocks settlement writes). */
export async function groupHasMoneyIssues(groupId: string): Promise<boolean> {
  const count = await prisma.moneyMigrationIssue.count({ where: { groupId } })
  return count > 0
}
