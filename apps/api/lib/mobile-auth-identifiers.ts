import crypto from 'crypto'

export function syntheticEmailForAppleSubject(subject: string) {
  const digest = crypto.createHash('sha256').update(subject).digest('hex').slice(0, 24)
  return `apple-${digest}@apple.billbandit.local`
}
