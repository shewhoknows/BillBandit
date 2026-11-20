export const REVIEW_ACCOUNT_ID = 'billbandit-review-account-v1'
export const REVIEW_ACCOUNT_EMAIL = 'reviewer@accounts.billbandit.invalid'
export const REVIEW_ACCOUNT_USERNAME = 'app_reviewer'
export const REVIEW_FRIEND_IDS = ['billbandit-review-aarav-v1', 'billbandit-review-kabir-v1', 'billbandit-review-ira-v1'] as const

export function reviewCodeEnabled(): boolean {
  return (process.env.BILLBANDIT_REVIEW_CODE?.length ?? 0) >= 16
}
