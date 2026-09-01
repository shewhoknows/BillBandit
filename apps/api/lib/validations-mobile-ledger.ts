import { z } from 'zod'

const nullToUndefined = (value: unknown) => (value === null ? undefined : value)
const optionalNullable = <T extends z.ZodTypeAny>(schema: T) =>
  z.preprocess(nullToUndefined, schema.optional())

const operationId = z
  .string()
  .min(1, 'Operation ID is required')
  .max(200, 'Operation ID is too long')
  .refine((value) => !/\s/.test(value), 'Operation ID cannot contain whitespace')

const expectedRevision = z
  .number()
  .int('Expected revision must be a whole number')
  .nonnegative('Expected revision must be non-negative')

/** JSON-safe exact money. Numeric major-unit amounts are deliberately absent. */
export const exactMoneySchema = z.object({
  minorUnits: z
    .string()
    .regex(/^(0|-?[1-9]\d*)$/, 'minorUnits must be a canonical signed integer string'),
  currencyCode: z
    .string()
    .regex(/^[A-Z]{3}$/, 'currencyCode must be an uppercase three-letter code'),
  currencyExponent: z
    .number()
    .int('currencyExponent must be a whole number')
    .min(0)
    .max(9),
})

const exactSplitSchema = z
  .object({
    id: optionalNullable(z.string()),
    splitId: optionalNullable(z.string()),
    memberId: optionalNullable(z.string()),
    userId: optionalNullable(z.string()),
    accountId: optionalNullable(z.string()),
    amount: exactMoneySchema,
    percentage: optionalNullable(z.number().finite().min(0).max(100)),
    shares: optionalNullable(z.number().int().min(1)),
    isPaid: z.boolean().optional(),
  })
  .passthrough()
  .superRefine((value, context) => {
    if (!value.memberId && !value.userId && !value.accountId) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['memberId'],
        message: 'A memberId or accountId is required',
      })
    }
  })

/** Shared-ledger expense body accepted by the mobile route adapters. */
export const mobileExpenseV2Schema = z
  .object({
    operationId: operationId.optional(),
    expectedRevision: expectedRevision.optional(),
    groupId: z.string().min(1, 'Group ID is required'),
    expenseId: optionalNullable(z.string()),
    id: optionalNullable(z.string()),
    description: z.string().min(1, 'Description is required').max(100),
    amount: exactMoneySchema,
    currency: z.string().regex(/^[A-Z]{3}$/, 'currency must be an uppercase three-letter code').optional(),
    date: z.string().or(z.date()).optional(),
    category: z.string().max(100).optional(),
    paidByMemberId: optionalNullable(z.string()),
    paidById: optionalNullable(z.string()),
    accountId: optionalNullable(z.string()),
    splitMethod: z.enum(['EQUAL', 'EXACT', 'PERCENTAGE', 'SHARES']).optional(),
    splitType: z.enum(['EQUAL', 'EXACT', 'PERCENTAGE', 'SHARES']).optional(),
    splits: z.array(exactSplitSchema).min(1, 'At least one split is required'),
    notes: optionalNullable(z.string().max(500)),
    receiptUrl: optionalNullable(z.string()),
    isRecurring: z.boolean().optional(),
    recurringInterval: z.enum(['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY']).nullable().optional(),
    recurringEndDate: z.string().or(z.date()).nullable().optional(),
  })
  .passthrough()
  .superRefine((value, context) => {
    if (!value.paidByMemberId && !value.paidById && !value.accountId) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['paidByMemberId'],
        message: 'A paidByMemberId or accountId is required',
      })
    }
    if (value.splitMethod && value.splitType && value.splitMethod !== value.splitType) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['splitMethod'],
        message: 'splitMethod and splitType must agree',
      })
    }
  })

export const mobileExpenseDeleteV2Schema = z
  .object({
    operationId: operationId.optional(),
    expectedRevision: expectedRevision.optional(),
    expenseId: optionalNullable(z.string()),
    id: optionalNullable(z.string()),
  })
  .passthrough()

export const mobileMembershipV2Schema = z
  .object({
    operationId: operationId.optional(),
    expectedRevision: expectedRevision.optional(),
    userId: optionalNullable(z.string()),
    accountId: optionalNullable(z.string()),
    memberId: optionalNullable(z.string()),
    role: z.enum(['ADMIN', 'MEMBER']).optional(),
    displayName: optionalNullable(z.string().max(200)),
  })
  .passthrough()

export const mobileFinalizeV2Schema = z
  .object({
    operationId: operationId.optional(),
    expectedRevision: expectedRevision.optional(),
  })
  .passthrough()

export type ExactMoneyInput = z.infer<typeof exactMoneySchema>
export type MobileExpenseV2Input = z.infer<typeof mobileExpenseV2Schema>
export type MobileMembershipV2Input = z.infer<typeof mobileMembershipV2Schema>

export const createGroupSchema = z.object({
  name: z.string().min(1, 'Group name is required').max(50),
  description: optionalNullable(z.string().max(200)),
  currency: z.string().default('INR'),
  category: z.enum(['HOME', 'TRIP', 'COUPLE', 'WORK', 'OTHER']).default('OTHER'),
})

export const addMemberSchema = z.object({
  email: z.string().email('Invalid email address'),
})

export const splitSchema = z.object({
  userId: z.string(),
  amount: z.number().min(0),
  percentage: optionalNullable(z.number().min(0).max(100)),
  shares: optionalNullable(z.number().min(1)),
})

export const createExpenseSchema = z.object({
  description: z.string().min(1, 'Description is required').max(100),
  amount: z.number().positive('Amount must be positive'),
  currency: z.string().default('INR'),
  date: z.string().or(z.date()),
  category: z.string().default('general'),
  groupId: optionalNullable(z.string()),
  paidById: z.string(),
  splitType: z.enum(['EQUAL', 'EXACT', 'PERCENTAGE', 'SHARES']),
  splits: z.array(splitSchema).min(1, 'At least one split is required'),
  notes: optionalNullable(z.string().max(500)),
  isRecurring: z.boolean().default(false),
  recurringInterval: z.enum(['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY']).optional(),
})

export type CreateGroupInput = z.infer<typeof createGroupSchema>
export type CreateExpenseInput = z.infer<typeof createExpenseSchema>
