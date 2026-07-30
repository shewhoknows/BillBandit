import { z } from 'zod'

export const appleSignInSchema = z.object({
  identityToken: z.string().min(20, 'Apple identity token is required'),
  nonce: z.string().optional(),
  name: z.string().min(1).optional(),
  fullName: z.string().min(1).optional(),
  authorizationCode: z.string().optional(),
  email: z.string().email().optional(),
})

export type AppleSignInInput = z.infer<typeof appleSignInSchema>
