# BillBandit external beta checklist

## 1. Real-device collaboration smoke test

- Install BillBandit 1.0 (7) on two registered iPhones signed into different
  iCloud accounts.
- Device A: open a group, tap **Invite**, and share it with Device B.
- Device B: accept the invitation. If names do not match automatically, choose
  the correct person in the branded member-matching screen.
- Device A: add an expense. Confirm Device B receives it after opening the app.
- Device B: edit the expense and record a partial settlement. Confirm Device A's
  invoice, balances, and Activity feed update.
- Test one offline edit, then reconnect and foreground the app to verify retry.
- Confirm an empty shared group remains **ALL SQUARE** on both devices.

## 2. CloudKit production gate

- [x] Open CloudKit Console for `iCloud.com.billbandit.app`.
- [x] Import and validate `CloudKit/CloudKitSchema.ckdb` into Development if the app
  has not already created the record types just in time.
- [x] Confirm development record types: `BBGroup`, `BBPerson`, `BBExpense`,
  `BBSettlement`, and `BBActivity`.
- [x] Deploy the development schema to Production. TestFlight uses Production; a
  development-only schema will make collaboration fail in the external beta.
- [x] Grant authenticated iCloud users `CREATE` permission for all seven public
  BillBandit record types and redeploy the security-role change to Production.
  CloudKit Console confirmed **Changes Deployed** on 2026-07-20.
- Do not reset the development environment after real testers begin using it.

## 3. App Store Connect

- [x] Resolve the App Store record mismatch. The obsolete legacy record was
  deleted and canonical BillBandit app ID `6792712181` now uses
  `com.billbandit.app` (SKU `BILLBANDIT-IOS-2026`).
- [ ] Complete App Privacy truthfully for the synced profile/member names, user ID,
  group expenses/settlements, and other user-created group content. No tracking
  or third-party advertising is present in this build.
- [x] Add the TestFlight beta description, feedback email, beta review contact,
  review notes, and build-specific testing instructions.
- [ ] Add a privacy-policy URL before App Store release. The TestFlight form
  accepted the current beta submission without one.
- [x] Export and upload build 6 with App Store Connect distribution signing.
  Version 1.0 (6) finished processing on 2026-07-20.
- [x] Complete build 6 export-compliance questions (no custom/non-exempt
  encryption).
- [x] Create **BillBandit Internal QA** and **BillBandit Public Beta**. Build 5
  was withdrawn and removed from the public group; build 6 replaced it and was
  submitted for Beta App Review. That review request was withdrawn on 2026-07-20
  while product work continues. Current build 6 status: **Ready to Submit**.
- [x] Create an open-to-anyone public link with no tester cap:
  `https://testflight.apple.com/join/JR7WttFq`.
- [ ] When the next candidate is ready, upload it, complete export compliance,
  add it to **BillBandit Public Beta**, and submit it for Beta App Review.
- [ ] After Apple approves the next candidate, verify the public link accepts a
  tester and complete the two-account collaboration smoke test.
- [x] Publish device-test build 7 through Sqim and verify its manifest:
  `https://build.sqim.dev/sqim/install/2l9N6CzTMGfO` (`com.billbandit.app`, build 7).

## 4. Suggested first cohort

- 5–10 people across at least two shared groups.
- Include one small-screen iPhone and one device using Reduce Motion.
- Ask testers to exercise invitation acceptance, simultaneous edits, offline
  recovery, expense deletion, settlement limits, and activity notifications.
