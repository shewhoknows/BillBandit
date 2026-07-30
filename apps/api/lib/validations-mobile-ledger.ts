import { z } from 'zod'

const nullToUndefined = (value: unknown) => (value === null ? undefined : value)
const optionalNullable = <T extends z.ZodTypeAny>(schema: T) =>
  z.preprocess(nullToUndefined, schema.optional())

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
