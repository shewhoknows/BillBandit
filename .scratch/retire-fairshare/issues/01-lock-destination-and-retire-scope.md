# Lock destination and retire scope

Type: grilling
Status: resolved

## Question

What does “retire FairShare into BillBandit” mean for destination, move set, layout, and cutover?

## Answer

(Round 1 — batch-grill-me, 2026-07-30)

1. **Destination:** BillBandit owns iOS + backend; prod API stays `billbandit-api.contenthelper.in`; FairShare not required day-to-day.
2. **Move set:** Settlement API surface + Sign in with Apple + unique username auth. **No** FairShare web UI.
3. **Layout:** `apps/ios/` + `apps/api/` monorepo inside BillBandit.
4. **Ink iOS:** Out of scope — published `com.billbandit.app` only.
5. **FairShare repo:** Archive (read-only), don’t delete.
6. **Cutover:** Copy API into BillBandit → wire CI/Railway to BillBandit `main` → verify settle-up/auth on prod → freeze FairShare deploys.

## Comments

- User answers: `1 ok 2 apps settlement only, no web. auth via 'sign in with apple' and a unique username 3 ok 4 ok 5 ok 6 ok`
