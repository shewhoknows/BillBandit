# BillBandit / FairShare Mobile API Contract

Base URL: `https://billbandit-api.contenthelper.in`
All mobile endpoints live under `/api/mobile/...`. All requests and responses are JSON (`Content-Type: application/json`).

Source of truth (read-only audit, 2026-07-08):
- Routes: `/Users/prateekranka/Cowork/FairShare/apps/web/app/api/mobile/**/route.ts`
- Auth: `/Users/prateekranka/Cowork/FairShare/apps/web/lib/mobile-auth.ts`
- DTOs: `/Users/prateekranka/Cowork/FairShare/apps/web/lib/mobile-dto.ts`
- Validation: `/Users/prateekranka/Cowork/FairShare/apps/web/lib/validations.ts`
- Schema: `/Users/prateekranka/Cowork/FairShare/apps/web/prisma/schema.prisma`

---

## Authentication scheme (applies to all protected endpoints)

- Header: `Authorization: Bearer <token>` (regex-matched case-insensitively as `Bearer <token>`).
- Token: a **hand-rolled HS256 JWT** (`header.payload.signature`, base64url, HMAC-SHA256 signed with `MOBILE_JWT_SECRET` or fallback `NEXTAUTH_SECRET`).
- JWT claims:
  ```json
  { "sub": "<userId cuid>", "email": "<email>", "name": "<name|null>", "iat": <unix>, "exp": <unix> }
  ```
- **Expiry: 30 days** (`TOKEN_TTL_SECONDS = 30 * 24 * 60 * 60`). Expired/invalid tokens → the session lookup fails.
- **There is NO refresh token and NO refresh endpoint.** When the token expires the client must re-authenticate (login / OTP / Apple).
- On every authenticated request the server also re-loads the user row by `sub`; if the user was deleted → 401.
- Auth failure response (all protected endpoints): `401 {"error": "Unauthorized"}`.
- Token issuance: `auth/register`, `auth/login`, `auth/otp/verify`, `auth/apple` all return the same shape: `{ "token": string, "user": MobileUser }`.

### Shared DTO: `MobileUser`

Returned by every endpoint that includes a user object (`mobileUser()` in mobile-dto.ts). All fields always present:

```json
{
  "id": "string (cuid)",
  "name": "string | null",
  "email": "string | null",
  "image": "string | null",          // URL (dicebear avatar by default)
  "phone": "string | null",          // E.164-ish, e.g. "+9198..."
  "preferredName": "string | null",
  "upiID": "string | null",
  "isProfileComplete": true          // boolean: Boolean((name ?? preferredName) && upiID)
}
```

Note: nested users inside expenses/groups are built from partial Prisma selects (often only `id,name,email,image`), so `phone`/`preferredName`/`upiID` will be `null` there even if set — model them all as optional/nullable in Swift.

### Shared DTO: `MobileMember`

```json
{
  "userId": "string",
  "role": "ADMIN" | "MEMBER",
  "joinedAt": "string (ISO 8601) | null",
  "user": MobileUser
}
```

### Shared DTO: `MobileExpense`

```json
{
  "id": "string",
  "description": "string",
  "amount": 123.45,                  // number (decimal, 2dp)
  "currency": "INR",                 // ISO-ish code string
  "date": "2026-07-01T00:00:00.000Z",// ISO 8601
  "category": "general",             // free string, default "general"
  "groupId": "string | null",
  "group": { "id": "string", "name": "string" } | null,
  "paidById": "string",
  "paidBy": MobileUser | null,
  "splitType": "EQUAL" | "EXACT" | "PERCENTAGE" | "SHARES",
  "notes": "string | null",
  "splits": [
    {
      "userId": "string",
      "amount": 61.73,               // number: what this user owes (absolute amount, NOT delta)
      "percentage": 50.0 | null,     // only meaningful for PERCENTAGE
      "shares": 2 | null,            // Int, only meaningful for SHARES
      "user": MobileUser | null
    }
  ],
  "createdAt": "ISO 8601 | null",
  "updatedAt": "ISO 8601 | null"
}
```

Splits semantics: every participant (including the payer, typically) has a split row whose `amount` is their share of the total. Split amounts must sum to `amount` within ±0.02. `percentage`/`shares` are stored as metadata of how the split was derived; the server never recomputes from them.

### Shared DTO: `MobileGroup`

```json
{
  "id": "string",
  "name": "string",
  "description": "string | null",
  "image": "string | null",
  "currency": "INR",
  "category": "HOME" | "TRIP" | "COUPLE" | "WORK" | "OTHER",
  "status": "ACTIVE" | "FINALIZED",  // derived: finalizedAt ? FINALIZED : ACTIVE
  "finalizedAt": "ISO 8601 | null",
  "finalizedById": "string | null",
  "memberCount": 3,                  // Int
  "expenseCount": 12,                // Int (non-deleted expenses)
  "members": [MobileMember],
  "expenses": [MobileExpense],       // OMITTED (undefined, key absent) on list endpoints; present on GET groups/[id] and finalize
  "createdAt": "ISO 8601 | null",
  "updatedAt": "ISO 8601 | null"
}
```

**Important for Codable:** `expenses` is `undefined` (key absent from JSON) when the group was loaded without expenses (GET /groups, dashboard, POST /groups). Model as optional `[MobileExpense]?`.

### Error shape (universal)

Every error is `{"error": "<message string>"}` with an appropriate status. Validation errors return the **first** zod issue message only. No error codes, no field maps.

---

## Endpoints

### POST /api/mobile/auth/apple

Auth: none.

Request body (`appleSignInSchema`):

```json
{
  "identityToken": "string",         // REQUIRED, min 20 chars. Apple identity token (JWT from Sign in with Apple)
  "nonce": "string?",                // optional; if sent, must match the token's nonce claim
  "name": "string?",                 // optional display name (min 1)
  "fullName": "string?",             // optional alias for name; server uses name ?? fullName
  "authorizationCode": "string?",    // accepted but IGNORED by the server
  "email": "string?"                 // optional; used only if token itself has no email claim
}
```

Server behavior:
1. Verifies `identityToken` against Apple JWKS (`https://appleid.apple.com/auth/keys`), issuer `https://appleid.apple.com`, audience = `APPLE_CLIENT_ID` ?? `IOS_BUNDLE_ID` ?? `NEXT_PUBLIC_IOS_BUNDLE_ID` ?? `"com.esha.fareshare"`.
2. If `nonce` provided, it must equal the token's `nonce` claim (raw nonce comparison, not hashed — client must pass the same raw value that ended up in the token).
3. Looks up `Account(provider='apple', providerAccountId=<token sub>)`. If linked → returns that user.
4. Else: if an email is known (token email ?? body email) and a user exists with that email → links Apple account to it. Otherwise creates a new user with email = token/body email or synthetic `apple-<sha256(sub)[0..24]>@apple.billbandit.local`, a dicebear avatar image, `name`/`preferredName` from body.
5. Test bypass: if env `MOBILE_AUTH_MOCK_APPLE_SUBJECT`/`MOBILE_AUTH_MOCK_APPLE_TOKEN` are set and identityToken equals the mock token, verification is skipped.

Responses:
- 200 `{ "token": string, "user": MobileUser }`
- 400 `{"error": "<zod message>"}` (invalid body)
- 401 `{"error": "Apple sign-in failed"}` (token verification failure, bad nonce, or any other error)

### POST /api/mobile/auth/register

Auth: none.

Request (`registerSchema`):
```json
{ "name": "string (min 2)", "email": "string (valid email)", "password": "string (min 8)" }
```

Responses:
- 201 `{ "token": string, "user": MobileUser, "message": string }` — message varies ("Registration successful! Please check your email to verify your account." or console-log variant in dev). Token is issued immediately; email verification is not required to use the API.
- 400 zod error; 409 `{"error": "An account with this email already exists"}`; 500 `{"error": "Internal server error"}`.

Side effect: sends a verification email (web flow); password stored as bcrypt(12).

### POST /api/mobile/auth/login

Auth: none.

Request (`loginSchema`):
```json
{ "email": "string (valid email)", "password": "string (min 1)" }
```

Responses:
- 200 `{ "token": string, "user": MobileUser }`
- 400 zod error
- 401 `{"error": "Invalid email or password"}` — also returned for OAuth/OTP-only users with no password set
- 500 `{"error": "Internal server error"}`

### POST /api/mobile/auth/otp/start

Auth: none.

Request (`otpStartSchema`):
```json
{ "identifier": "string (min 3)" }   // email OR phone number
```

Identifier normalization:
- Contains `@` → treated as email (lowercased, must match `/^[^\s@]+@[^\s@]+\.[^\s@]+$/`).
- Otherwise treated as phone: non-digits stripped, `+` prefixed if missing, must have 8–15 digits ("Enter a valid phone number with country code").

Response 200:
```json
{
  "challengeId": "string (cuid)",
  "maskedIdentifier": "string",       // e.g. "pr••••••@gmail.com" or "+9•••••1234" (uses U+2022 bullets)
  "deliveryChannel": "email" | "phone",
  "expiresInSeconds": 600,
  "message": "string"
}
```

Errors:
- 400 `{"error": "Enter a valid email address" | "Enter a valid phone number with country code" | <zod msg>}`
- **501** `{"error": "Phone OTP delivery is not configured yet. Set MOBILE_AUTH_TEST_CODE for QA or add an SMS provider."}` — **phone OTP delivery is NOT implemented** unless the identifier is on the `MOBILE_AUTH_TEST_IDENTIFIERS` allowlist (then the fixed `MOBILE_AUTH_TEST_CODE` is used and nothing is sent).
- 500 internal.

OTP: 6-digit code, 10-minute TTL, stored as HMAC-SHA256(`challengeId:code`) in `MobileOTPChallenge`.

### POST /api/mobile/auth/otp/verify

Auth: none.

Request (`otpVerifySchema`):
```json
{ "challengeId": "string", "code": "string, exactly 6 digits (regex ^\\d{6}$)" }
```

Responses:
- 200 `{ "token": string, "user": MobileUser }` — finds or **creates** the user:
  - email identifier → new user gets `name`/`preferredName` = email local part, `emailVerified` set.
  - phone identifier → new user gets `phone` set and synthetic email `phone-<sha256(phone)[0..24]>@phone.billbandit.local`; `name` stays null.
- 400 `{"error": "Code expired. Request a new one."}` — unknown/consumed/expired challenge
- 401 `{"error": "Invalid code"}` (attempt counter incremented; challenge stays live)
- 429 `{"error": "Too many attempts. Request a new code."}` — after 5 failed attempts
- 400 zod error; 500 internal.

Challenges are single-use (`consumedAt` set on success).

### GET /api/mobile/auth/me

Auth: Bearer required.

Response 200: `{ "user": MobileUser }`. 401 otherwise.

### PUT /api/mobile/auth/profile

Auth: Bearer required.

Request (`completeMobileProfileSchema`) — all fields optional, only provided ones are updated:
```json
{
  "name": "string? (2..80)",
  "preferredName": "string? (1..40)",
  "upiID": "string? (3..120)"
}
```

Responses: 200 `{ "user": MobileUser }`; 400 zod; 401; 500.
Note: this is the only way to set `upiID`, which drives `isProfileComplete`. There is **no way to update `image`/avatar or `phone`/`email`** here.

### GET /api/mobile/dashboard

Auth: Bearer required.

No query params. Response 200:

```json
{
  "balances": [
    { "user": MobileUser, "amount": 123.45 }   // positive = they owe me; negative = I owe them
  ],
  "totalOwed": 200.00,     // sum of positive balances (owed TO me)
  "totalOwe": 50.00,       // sum of |negative| balances (I owe)
  "currency": "INR",       // most frequent currency among the recent expenses; "INR" if none
  "recentExpenses": [MobileExpense],   // max 5, ordered date desc
  "groups": [MobileGroup]              // max 5, updatedAt desc, WITHOUT "expenses" key
}
```

**Gotcha:** `balances` here is computed only from the **5 most recent expenses** (plus all transactions), not the full ledger — it is an approximation. Balances with |amount| ≤ 0.005 are filtered out. Amounts rounded to 2dp.

### GET /api/mobile/expenses

Auth: Bearer required.

Query params:
- `groupId` (optional string). If present, caller must be a group member (else 403 `{"error":"Forbidden"}`); returns ALL non-deleted expenses of that group (not just ones involving the caller).
- `limit` (optional int, default 50, clamped to 1..100). **No offset/cursor — no real pagination.**

Response 200: `{ "expenses": [MobileExpense] }` ordered `date` desc. Without `groupId`, returns expenses where caller is payer or has a split.

### POST /api/mobile/expenses

Auth: Bearer required.

Request (`createExpenseSchema`):
```json
{
  "description": "string (1..100)",              // REQUIRED
  "amount": 123.45,                              // REQUIRED, number > 0
  "currency": "INR",                             // optional string, default "INR"
  "date": "2026-07-01T00:00:00Z",                // REQUIRED, string (parsed with new Date())
  "category": "general",                         // optional string, default "general"
  "groupId": "string | null | absent",           // optional (null accepted, treated as absent)
  "paidById": "string",                          // REQUIRED — may be any member, not just the caller
  "splitType": "EQUAL" | "EXACT" | "PERCENTAGE" | "SHARES",  // REQUIRED
  "splits": [                                     // REQUIRED, min 1
    {
      "userId": "string",                        // REQUIRED
      "amount": 61.73,                           // REQUIRED, number >= 0
      "percentage": 50.0,                        // optional/null, 0..100
      "shares": 2                                // optional/null, number >= 1
    }
  ],
  "notes": "string | null | absent (max 500)",
  "isRecurring": false,                          // optional boolean, default false
  "recurringInterval": "DAILY"|"WEEKLY"|"MONTHLY"|"YEARLY"  // optional
}
```

Validation/behavior:
- If `groupId` set: caller must be a member (403 Forbidden), group must not be finalized (409 `{"error":"Group is finalized"}`), every split `userId` and `paidById` must be group members (400).
- Sum of split amounts must equal `amount` within 0.02 → else 400 `{"error": "Split amounts (X.XX) don't match expense total (Y.YY)"}`.
- Amounts are rounded to 2dp server-side (`roundAmount`).
- The server does NOT verify splits against `splitType`/percentage/shares — client computes split amounts.

Responses: **201** `{ "expense": MobileExpense }`; 400/401/403/409/500 with `{"error"}`.

### GET /api/mobile/expenses/{id}

Auth: Bearer required.

Responses:
- 200 `{ "expense": MobileExpense }` — caller must be payer or a split participant
- 404 `{"error":"Not found"}` (also for soft-deleted expenses)
- 403 `{"error":"Forbidden"}`

### PUT /api/mobile/expenses/{id}

Auth: Bearer required. **Only the current payer (`paidById`) may edit** → else 403 `{"error":"Only the payer can edit an expense"}`.

Request body: same as POST /expenses (`createExpenseSchema`) — a full replace, not a patch. All splits are deleted and recreated. `isRecurring`/`recurringInterval` are accepted by the schema but NOT persisted on update (only description, amount, currency, date, category, groupId, paidById, splitType, notes, splits).

Responses:
- 200 `{ "expense": MobileExpense }`
- 404 Not found; 403 payer-only or non-member of target group; 409 `{"error":"Group is finalized"}` (either the expense's current group or the target group); 400 split-sum mismatch / zod; 500.

### DELETE /api/mobile/expenses/{id}

Auth: Bearer required. Payer only (403 `{"error":"Only the payer can delete an expense"}`).

- Soft delete (`isDeleted = true`).
- 409 `{"error":"Group is finalized"}` if in a finalized group.
- 200 `{ "success": true }`; 404 if missing.

### GET /api/mobile/groups

Auth: Bearer required.

Response 200: `{ "groups": [MobileGroup] }` — all non-archived groups where the caller is a member, ordered `updatedAt` desc, **no `expenses` key** in each group (memberCount/expenseCount still populated). No pagination.

### POST /api/mobile/groups

Auth: Bearer required.

Request (`createGroupSchema`):
```json
{
  "name": "string (1..50)",                       // REQUIRED
  "description": "string | null | absent (max 200)",
  "currency": "INR",                              // optional, default "INR"
  "category": "HOME"|"TRIP"|"COUPLE"|"WORK"|"OTHER"  // optional, default "OTHER"
}
```

Creator is added as the sole member with role `ADMIN`.

Responses: **201** `{ "group": MobileGroup }` (no `expenses` key); 400/401/500.

### GET /api/mobile/groups/{id}

Auth: Bearer required; caller must be a member → else 403 `{"error":"Forbidden"}` (returned even for nonexistent groups, since membership is checked first; 404 `{"error":"Group not found"}` only in a race).

Response 200:
```json
{
  "group": MobileGroup,          // WITH "expenses": [MobileExpense] (non-deleted, date desc); members ordered joinedAt asc
  "balances": {
    "netBalances": [
      { "userId": "string", "name": "string|null", "image": "string|null", "netAmount": 12.34 }
      // netAmount: positive = this member is owed money; negative = owes. Rounded 2dp. One entry per member (including zeros).
    ],
    "simplifiedDebts": [
      { "fromId": "string", "toId": "string", "amount": 12.34, "fromName": "string|null", "toName": "string|null" }
      // minimal payment set (greedy largest-creditor/largest-debtor); amount always positive; "from" pays "to"
    ]
  }
}
```

Balance semantics: net = (sum of others' split amounts on expenses you paid) − (your split amounts on expenses others paid), adjusted by transactions (sender gains credit, receiver loses credit). Sub-cent noise (< 0.005) dropped.

### POST /api/mobile/groups/{id}/finalize

Auth: Bearer required; caller must be a member with role `ADMIN` → else 403 `{"error":"Forbidden"}`.

Request body: none (empty; body is ignored).

Behavior: sets `finalizedAt = now`, `finalizedById = caller` — only if not already finalized (idempotent; re-calling returns current state). **There is NO reopen/un-finalize endpoint.** Once finalized: expense create/edit/delete in the group and member additions all return 409 `{"error":"Group is finalized"}`. Transactions (settlements) are still allowed in a finalized group.

Response 200: same shape as GET /groups/{id} (`{ group, balances: { netBalances, simplifiedDebts } }`, group includes expenses). 404 `{"error":"Group not found"}` if group vanished.

### POST /api/mobile/groups/{id}/members

Auth: Bearer required; caller must be a member (any role) → else 403. Group must not be finalized → 409 `{"error":"Group is finalized"}`.

Request (`addMemberSchema`):
```json
{ "email": "string (valid email)" }
```

Behavior: the user **must already exist** — there is no invitation/pending-member concept. Added with role `MEMBER`.

Responses:
- **201** `{ "member": MobileMember }`
- 404 `{"error":"No user found with that email address"}`
- 409 `{"error":"User is already a member of this group"}`
- 400 zod; 401; 403; 409 finalized.

**There is NO endpoint to remove a member, change roles, leave a group, edit a group, delete/archive a group, or list members separately** (members come embedded in group responses).

### POST /api/mobile/transactions

Auth: Bearer required. Records a settlement payment.

Request (`createTransactionSchema`):
```json
{
  "receiverId": "string | null | absent",   // "I paid <receiverId>"
  "senderId": "string | null | absent",     // "<senderId> paid me"
  "amount": 123.45,                          // REQUIRED, number > 0
  "currency": "INR",                         // optional, defaults to "INR"
  "groupId": "string | null | absent",
  "note": "string | null | absent (max 200)"
}
```

Rules:
- Exactly ONE of `receiverId` / `senderId` must be provided → else 400 `{"error":"Provide exactly one of receiverId or senderId"}`. The caller is implicitly the other party.
- Sender ≠ receiver → 400 `{"error":"You can't settle with yourself"}`.
- 404 `{"error":"Sender not found"}` / `{"error":"Receiver not found"}`.
- If `groupId` set: caller, sender, and receiver must all be group members → 403 `{"error":"Both settlement parties must belong to the group"}`. (Finalized groups still accept transactions.)

Response **201**:
```json
{
  "transaction": {
    "id": "string",
    "amount": 123.45,
    "currency": "INR",
    "note": "string | null",
    "group": { "id": "string", "name": "string" } | null,
    "sender":   { "id": "string", "name": "string|null", "image": "string|null", "email": "string" },
    "receiver": { "id": "string", "name": "string|null", "image": "string|null", "email": "string" },
    "createdAt": "ISO 8601"
  }
}
```

Note: sender/receiver here are RAW prisma selections (`id,name,image,email`), NOT the MobileUser DTO — no `phone`/`preferredName`/`upiID`/`isProfileComplete` keys.

**There is NO GET /api/mobile/transactions** — settlements are only visible via their effect on balances (group detail, dashboard). Transactions cannot be edited or deleted.

### GET /api/mobile/users/lookup?email=<email>

Auth: Bearer required.

Query param: `email` (trimmed + lowercased server-side; must be a valid email).

Response 200 (always 200, never 404):
- Found (and not the caller): `{ "exists": true, "user": MobileUser }`
- Not found / invalid email / it's your own email: `{ "exists": false, "user": null }`

---

## Auth flow summary

**Sign in with Apple (`POST /api/mobile/auth/apple`):** the iOS client performs native Sign in with Apple and sends the **`identityToken`** (the JWT string from `ASAuthorizationAppleIDCredential.identityToken`). Optionally: the raw `nonce` used in the request (server compares it to the token's `nonce` claim — send the raw nonce, matching whatever ended up in the token), `name`/`fullName` (only available on the first authorization; used for new-user creation), and `email` (fallback if the token lacks an email claim, e.g. subsequent sign-ins). `authorizationCode` is accepted by the schema but completely ignored — no server-side token exchange happens. Accounts are keyed by the Apple `sub` in the `Account` table; email matching auto-links an existing account on first Apple sign-in.

**Email+password:** `POST auth/register` (creates user, bcrypt password, fires verification email but issues a token immediately) and `POST auth/login`. Users created via Apple/OTP have no password and cannot use login.

**OTP:** `POST auth/otp/start` with `{identifier}` (email or E.164 phone) → `{challengeId, ...}`; then `POST auth/otp/verify` with `{challengeId, code}` → token. Email OTP works via SMTP; **phone OTP returns 501 in production** (no SMS provider) except for env-allowlisted QA identifiers with a fixed test code. Verify auto-creates users (find-or-create by email or phone).

**Token lifecycle:** every successful auth returns a 30-day HS256 JWT. **No refresh endpoint, no logout endpoint, no token revocation** — clients store the token, send `Authorization: Bearer <token>`, and re-authenticate on 401. `GET auth/me` validates a stored token and refreshes the user profile.

## Endpoints that DO NOT exist

No backend support for any of the following (verified: the only mobile routes are the 16 files listed at top):

- **Friend codes / invite codes** — nothing anywhere. Members are added strictly by exact email of an existing user.
- **Trip/group invite links** — none. No pending/invited member state; `GroupMember` rows only exist for real users.
- **Settlements persistence/read API** — `POST /transactions` writes, but there is **no GET/list/edit/delete for transactions**; no "settlement" entity beyond the Transaction row. Simplified debts are computed on the fly, never persisted.
- **Friends list** — the Prisma `Friendship` model (PENDING/ACCEPTED/REJECTED) exists in the schema but **no mobile endpoint reads or writes it**. "People you owe" comes from expense/transaction math, not a friends table.
- **Avatar upload** — none. `image` is set server-side to a dicebear URL at signup and cannot be changed via the mobile API (profile PUT only accepts name/preferredName/upiID).
- **Sync/delta endpoints** — none. No etags, no updated-since params, no websocket/push. Clients must re-fetch.
- Also absent: member removal, role change, leave group, group edit/archive/delete, group reopen (un-finalize), expense comments (Comment model exists, no mobile route), activity feed (ActivityLog is write-only side effect), receipts (`receiptUrl` never set), password reset, logout/token revocation, token refresh, pagination cursors.

## Money / currency semantics

- **All amounts are JSON numbers representing decimal major units** (e.g. `123.45` = ₹123.45), stored as Postgres `Float` (Prisma `Float`) — **NOT minor units/cents, NOT string decimals**. In Swift use `Double` (or decode via Double and convert to Decimal; beware float artifacts like `0.30000000000000004` are possible in stored data, though the server rounds writes).
- Server rounds expense and split amounts to 2dp on write (`Math.round(x*100)/100`); balance calculations round to 2dp and treat |x| ≤ 0.005 as zero.
- Split-sum validation tolerance: ±0.02 against the expense total.
- `currency` is a free-form string code per expense / group / transaction. Mobile-facing default is `"INR"` everywhere (zod defaults), though the Prisma column default is `"USD"` (irrelevant since zod always supplies a value). **No currency conversion**: balances/debts naively sum amounts across currencies; the dashboard's `currency` field is just the modal currency of recent expenses.
- `Transaction.currency` defaults to `"INR"` if omitted/null.

## Prisma models relevant to mobile (summary)

- **User**: `id (cuid), name?, email (unique, required — synthetic for phone/Apple-private users), emailVerified?, image?, password? (bcrypt, null for OAuth/OTP), phone? (unique), preferredName?, upiID?, createdAt, updatedAt`.
- **Account**: NextAuth-style OAuth link — `(provider, providerAccountId)` unique; Apple sign-in stores `provider='apple'`, `providerAccountId=<apple sub>`, `type='oauth'`.
- **MobileOTPChallenge**: `id, identifier, identifierType ('email'|'phone'), codeHash (HMAC), expiresAt, consumedAt?, attempts (default 0)`.
- **Group**: `id, name, description?, image?, currency (default "USD" at DB), category (HOME|TRIP|COUPLE|WORK|OTHER), isArchived (default false), finalizedAt?, finalizedById?, createdAt, updatedAt`.
- **GroupMember**: `id, groupId, userId, role (ADMIN|MEMBER, default MEMBER), joinedAt`; unique `(groupId,userId)`.
- **Expense**: `id, description, amount Float, currency, date, category (string, default "general"), groupId? (nullable — personal/non-group expenses allowed), paidById, splitType (EQUAL|EXACT|PERCENTAGE|SHARES), receiptUrl? (unused), notes?, isRecurring, recurringInterval? (DAILY|WEEKLY|MONTHLY|YEARLY), recurringEndDate? (unused), isDeleted (soft delete), createdAt, updatedAt`.
- **ExpenseSplit**: `id, expenseId, userId, amount Float, percentage Float?, shares Int?, isPaid (default false, never surfaced to mobile)`; unique `(expenseId,userId)`.
- **Transaction**: `id, senderId (payer), receiverId (payee), amount Float, currency (default "USD" at DB / "INR" via API), note?, groupId?, createdAt`. No updatedAt; immutable.
- **Friendship**: `fromId, toId, status (PENDING|ACCEPTED|REJECTED)` — schema-only for mobile; no routes.
- **Comment**, **ActivityLog**: exist; ActivityLog rows are written as side effects of mutations (types like EXPENSE_CREATED, PAYMENT_MADE) but there is no mobile read API for either.

## Gotchas

1. **"Group" is the API term; UI may say "trip"** — the `category` enum includes `TRIP`, but every endpoint/field says `group`/`groupId`. There is no separate trip entity.
2. **No pagination anywhere.** `GET /expenses` has only `limit` (default 50, max 100, no offset); `GET /groups` returns everything; dashboard caps at 5+5.
3. **Dates:** responses use ISO 8601 strings with milliseconds (`.toISOString()`, e.g. `2026-07-01T12:34:56.789Z`). Requests: expense `date` is any string `new Date()` can parse — send full ISO 8601. `joinedAt` in members may be null (defensive), everything else datish is null-or-ISO.
4. **`expenses` key absent vs present** on `MobileGroup` (see DTO note) — make it optional in Codable, and note list endpoints omit it entirely rather than sending `[]`.
5. **401 handling:** the ONLY unauthorized body is `{"error":"Unauthorized"}`; `auth/apple` returns 401 `{"error":"Apple sign-in failed"}` for any verification problem; login 401 is `{"error":"Invalid email or password"}`.
6. **403 vs 404:** group endpoints check membership BEFORE existence, so a wrong/foreign group id yields 403 Forbidden, not 404. Expense GET yields 404 for missing/soft-deleted, 403 for no access.
7. **`paidById` is client-supplied** on expense create/update and may be any group member (the caller "adds on behalf of"). But edit/delete authorization is payer-only, so an expense created with someone else as payer cannot be edited by its creator.
8. **Dashboard balances are approximate** (built from only the 5 most recent expenses + all transactions). Group detail balances are exact for that group.
9. **Finalize is one-way** via mobile — no reopen endpoint; finalized groups still accept settlements (`POST /transactions` with groupId) but reject expense mutations and member adds with 409.
10. **`splitType` is decorative server-side** — the server only validates that split `amount`s sum to the total (±0.02). Percentage/shares math is entirely the client's job.
11. **Required headers:** just `Authorization: Bearer <jwt>` and `Content-Type: application/json`. No API key, no app-version header, no CSRF.
12. **Synthetic emails:** users created via phone OTP or Apple private relay-less flow get `phone-…@phone.billbandit.local` / `apple-…@apple.billbandit.local` emails; these appear in `MobileUser.email` — don't render them as real contact info, and `users/lookup` by such an email will "work".
13. **`recurringInterval`/`isRecurring`** are stored on create but there is no server-side recurrence engine visible in the mobile API, and PUT drops them.
14. **Zod null preprocessing:** for fields wrapped in `optionalNullable` (group `description`, expense `groupId`/`notes`/split `percentage`/`shares`, transaction fields), sending JSON `null` is equivalent to omitting the field. Other optional fields (e.g. apple `nonce`, profile fields) must be omitted rather than null.
15. **Duplicate settlements are unguarded** — `POST /transactions` has no idempotency key; retries create double payments.
