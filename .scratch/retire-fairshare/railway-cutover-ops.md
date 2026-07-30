# Railway cutover ops — FairShare → BillBandit

**Audience:** repo admin / ops (human only).  
**Do not** run these steps from agents or CI. **Do not** paste secret values into tickets or chat.

**Prerequisite:** BillBandit `main` contains `apps/api`, root `package.json`, `Dockerfile`, `railway.toml`, and `.github/workflows/deploy.yml` (lanes A–E complete in working tree).

**Production URL (unchanged):** `https://billbandit-api.contenthelper.in`

---

## 1. Add GitHub Actions secrets on `shewhoknows/BillBandit`

Repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

Copy values from the FairShare repo’s existing secrets (same Railway project/service). Secret **names** required by [`.github/workflows/deploy.yml`](../../.github/workflows/deploy.yml):

| Secret name | Required | Notes |
|-------------|----------|-------|
| `RAILWAY_TOKEN` | Yes | Railway project deploy token |
| `RAILWAY_SERVICE_ID` | Yes | Target API service ID |
| `RAILWAY_ENVIRONMENT` | No | Defaults to `production` in workflow if unset |
| `RAILWAY_PROJECT_ID` | No | Passed to `railway up` when set |

No other GHA secrets are referenced by the deploy workflow.

---

## 2. Point Railway at BillBandit `main`

In the **Railway dashboard** (existing `billbandit-api` project):

1. Open the API **service** that serves `billbandit-api.contenthelper.in`.
2. **Settings** → connect source repo to **`shewhoknows/BillBandit`**, branch **`main`**.
3. Confirm build uses repo root **`Dockerfile`** (or `railway.toml` if configured).
4. **Do not** change the custom domain or Postgres plugin attachment.
5. Keep the same service so `DATABASE_URL` and hostname stay as-is.

Optional sanity check before cutover: trigger **workflow_dispatch** on BillBandit `Deploy to Railway` after secrets exist, or merge to `main` and watch the Actions run.

---

## 3. Confirm Railway environment variables (names only)

In Railway → service → **Variables**, confirm these are set (values must match current production — especially `DATABASE_URL` and `MOBILE_JWT_SECRET`):

**Required**

- `DATABASE_URL`
- `MOBILE_JWT_SECRET`
- `IOS_BUNDLE_ID` **or** `APPLE_CLIENT_ID` (both accepted; `com.billbandit.app`)

**Optional (realtime)**

- `PUSHER_APP_ID`
- `PUSHER_KEY`
- `PUSHER_SECRET`
- `PUSHER_CLUSTER`

**Optional (dev/QA only — omit in production)**

- `MOBILE_AUTH_MOCK_APPLE_SUBJECT`
- `MOBILE_AUTH_MOCK_APPLE_EMAIL`
- `SEED_ON_START`

**Auto-injected by Railway (no action)**

- `RAILWAY_GIT_COMMIT_SHA`, `RAILWAY_GIT_BRANCH`, `RAILWAY_ENVIRONMENT_NAME`, `RAILWAY_SERVICE_NAME`

Reference: [`apps/api/.env.example`](../../apps/api/.env.example).

> **Warning:** Rotating `MOBILE_JWT_SECRET` invalidates all existing mobile Bearer tokens; users must sign in again.

---

## 4. Disable FairShare deploy

On the **FairShare** GitHub repo (`shewhoknows/FairShare` or equivalent):

**Option A (preferred):** Repo → **Settings** → **Actions** → **Disable actions** (or disable the `Deploy to Railway` workflow).

**Option B:** Railway dashboard → disconnect or delete the FairShare-linked deploy source for this service (only if BillBandit is already connected per §2).

Verify: a push to FairShare `main` no longer deploys to production.

---

## 5. Verify production

### 5a. Curl smoke (no auth)

```bash
PROD=https://billbandit-api.contenthelper.in

# Expect HTTP 200 and JSON with status "ok"
curl -sS "$PROD/api/health" | jq .

# Expect HTTP 401 (missing Bearer token)
curl -sS -o /dev/null -w "settle-up HTTP %{http_code}\n" \
  "$PROD/api/groups/test/settle-up"
```

After a BillBandit deploy, health `commit` / `shortCommit` should match the GHA run SHA (see `public/deploy-info.json` written at deploy time).

### 5b. Live app (per ticket 05)

| Check | Owner |
|-------|-------|
| Sign in with Apple + unique username on **both** simulators | QA |
| Shared Settle Up loads on **LiveSettle-Test** | QA |
| One settlement mutation (e.g. mark paid / create settlement) succeeds | QA |

---

## 6. Archive FairShare (after §5 passes)

1. FairShare GitHub repo → **Settings** → **Danger zone** → **Archive repository**.
2. Add a README note pointing to `shewhoknows/BillBandit` (optional).
3. Mark checklist item 8 done in [issues/10-execution-checklist.md](issues/10-execution-checklist.md).

---

## Rollback (if needed)

1. Reconnect Railway source to FairShare `main` (last known-good commit).
2. Re-enable FairShare GHA deploy; disable BillBandit deploy workflow.
3. Investigate BillBandit deploy logs before retrying cutover.

---

## Related docs

- [issues/05-lock-railway-ci-cutover.md](issues/05-lock-railway-ci-cutover.md) — decision sequence
- [issues/10-execution-checklist.md](issues/10-execution-checklist.md) — full checklist
- [map.md](map.md) — migration map and status
