import { PrismaClient } from '@prisma/client'

export function createReviewResetClient() {
  return new PrismaClient({ transactionOptions: { timeout: 60_000, maxWait: 10_000 } })
}
