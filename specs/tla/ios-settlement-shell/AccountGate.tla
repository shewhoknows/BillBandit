---------------------------- MODULE AccountGate ----------------------------
(***************************************************************************)
(* AppRootView account gate (RootTabView.swift) + the mobile session       *)
(* (UsernameIdentity.swift) + ServerLedgerSurfaceStore (Home/Groups/       *)
(* Friends balances).                                                      *)
(*                                                                         *)
(* Concurrency that exists: prepareAccountGate awaits /auth/me and then an *)
(* Apple credential-state callback, while CloudCollaborationService.prepare*)
(* and the surface store send their own requests; any of them can get a   *)
(* 401, which clears the token (invalidateUnauthorizedSession). The person *)
(* can sign out, delete the account or sign in again.                     *)
(*                                                                         *)
(* FIXED = FALSE: base commit 372c5b3.  FIXED = TRUE: this slice's fixes.  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS FIXED, MaxGen, Max401

VARIABLES
  token,       \* MobileTokenStore holds a session token
  flags,       \* appleUserIdentifier != "" /\ accountOnboardingComplete /\ usernameHandleVerified
  gate,        \* accountGateState
  launchPc,    \* prepareAccountGate progress
  surf,        \* ServerLedgerSurfaceStore.status.phase
  surfData,    \* ServerLedgerSurfaceStore.snapshot != nil
  surfGen,     \* refreshGeneration
  refPc, refGen, refSawToken,
  n401,
  lostAfterAuth  \* ghost: session was lost while the app was already shown

vars == << token, flags, gate, launchPc, surf, surfData, surfGen, refPc, refGen,
           refSawToken, n401, lostAfterAuth >>

RootShown == gate = "authorized" /\ flags

Init ==
  /\ token \in BOOLEAN /\ flags \in BOOLEAN
  /\ gate = "checking" /\ launchPc = "start"
  /\ surf = "signedOut" /\ surfData = FALSE /\ surfGen = 0
  /\ refPc = "idle" /\ refGen = 0 /\ refSawToken = FALSE
  /\ n401 = 0 /\ lostAfterAuth = FALSE

\* the surface store forgets the account's balances (accountDidLoseAuthorization / SignOut)
SurfClear == /\ surf' = "signedOut" /\ surfData' = FALSE
             /\ surfGen' = IF surfGen < MaxGen THEN surfGen + 1 ELSE surfGen

(* ---------------- prepareAccountGate ---------------------------------- *)
LaunchStart ==
  /\ launchPc = "start"
  /\ IF flags
       THEN /\ launchPc' = "reconcile"
            /\ UNCHANGED << token, flags, gate, surf, surfData, surfGen >>
       ELSE \* .signedOut/.ambiguous or onboarding incomplete
            /\ launchPc' = "done" /\ gate' = "signedOut"
            /\ UNCHANGED << token, flags, surf, surfData, surfGen >>
  /\ UNCHANGED << refPc, refGen, refSawToken, n401, lostAfterAuth >>

\* reconcileUsernameAndVerifyAppleCredential: /auth/me finished
LaunchReconcile ==
  /\ launchPc = "reconcile"
  /\ IF ~token
       THEN /\ launchPc' = "done" /\ gate' = "signedOut" /\ flags' = FALSE
            /\ SurfClear
       ELSE \* verified (or a temporary outage with the session kept):
            \* verifyAppleCredential sets .checking and asks Apple
            /\ launchPc' = "credential" /\ gate' = "checking"
            /\ UNCHANGED << flags, surf, surfData, surfGen >>
  /\ UNCHANGED << token, refPc, refGen, refSawToken, n401, lostAfterAuth >>

\* getCredentialState callback (DispatchQueue.main.async)
CredentialCallback ==
  /\ launchPc = "credential"
  /\ launchPc' = "done"
  /\ \E authorize \in BOOLEAN :
       IF authorize
         THEN IF FIXED /\ ~token
                THEN \* session already gone: same as the reconcile no-session branch
                     /\ gate' = "signedOut" /\ flags' = FALSE /\ SurfClear
                     /\ UNCHANGED token
                ELSE /\ gate' = "authorized"
                     /\ UNCHANGED << token, flags, surf, surfData, surfGen >>
         ELSE \* revoked: full sign-out
              /\ gate' = "signedOut" /\ flags' = FALSE /\ token' = FALSE /\ SurfClear
  /\ UNCHANGED << refPc, refGen, refSawToken, n401, lostAfterAuth >>

(* ---------------- session events -------------------------------------- *)
\* any request (gate, CloudCollaboration.prepare, social poll, ledger) gets 401
Server401 ==
  /\ token /\ n401 < Max401
  /\ token' = FALSE /\ n401' = n401 + 1
  /\ lostAfterAuth' = (lostAfterAuth \/ RootShown)
  /\ IF FIXED THEN SurfClear ELSE UNCHANGED << surf, surfData, surfGen >>
  /\ UNCHANGED << flags, gate, launchPc, refPc, refGen, refSawToken >>

\* Profile "Sign out" and a confirmed "Delete account" (same end state)
SignOut ==
  /\ RootShown
  /\ token' = FALSE /\ flags' = FALSE
  /\ SurfClear
  /\ UNCHANGED << gate, launchPc, refPc, refGen, refSawToken, n401, lostAfterAuth >>

\* Onboarding (signed-out gate) or Profile (expired session) Apple sign-in
SignIn ==
  /\ ~token /\ launchPc = "done" /\ (gate = "signedOut" \/ RootShown \/ ~flags)
  /\ token' = TRUE /\ flags' = TRUE /\ gate' = "authorized"
  /\ surf' = "loading" /\ surfData' = FALSE
  /\ surfGen' = IF surfGen < MaxGen THEN surfGen + 1 ELSE surfGen
  /\ lostAfterAuth' = FALSE
  /\ UNCHANGED << launchPc, refPc, refGen, refSawToken, n401 >>

(* ---------------- ServerLedgerSurfaceStore.refresh(groups:) ------------ *)
RefStart ==
  /\ refPc = "idle" /\ RootShown
  /\ IF ~token
       THEN \* ensureActiveAccount: no stored session
            /\ surf' = "signedOut" /\ surfData' = FALSE
            /\ UNCHANGED << refPc, refGen, refSawToken, surfGen >>
       ELSE /\ surfGen < MaxGen
            /\ surfGen' = surfGen + 1 /\ refGen' = surfGen + 1
            /\ refPc' = "fetching" /\ refSawToken' = TRUE
            /\ UNCHANGED << surf, surfData >>
  /\ UNCHANGED << token, flags, gate, launchPc, n401, lostAfterAuth >>

RefEnd ==
  /\ refPc = "fetching"
  /\ refPc' = "idle"
  /\ IF refGen # surfGen
       THEN UNCHANGED << surf, surfData >>              \* superseded
       ELSE IF token
         THEN /\ surf' = "ready" /\ surfData' = TRUE
         ELSE \* the read got 401: errors + cached projection
              /\ surf' = (IF surfData THEN "cached" ELSE "error")
              /\ UNCHANGED surfData
  /\ UNCHANGED << token, flags, gate, launchPc, surfGen, refGen, refSawToken, n401, lostAfterAuth >>

Next == LaunchStart \/ LaunchReconcile \/ CredentialCallback \/ Server401
        \/ SignOut \/ SignIn \/ RefStart \/ RefEnd

Spec == Init /\ [][Next]_vars

(* ---------------- properties ------------------------------------------ *)
\* "Balances are current" only with a session.
ReadyNeedsSession == surf = "ready" => token

\* No account balances on screen without a session once the refresh is idle.
NoBalancesWithoutSession == (refPc = "idle" /\ ~token) => ~surfData

\* The app is shown only with a session, or after the session was lost while
\* it was already shown (the designed "session expired, sign in again in
\* Profile" state that keeps queued writes).
RootNeedsSession == RootShown => (token \/ lostAfterAuth)

\* The gate never shows the app while it is still checking.
NoRootWhileChecking == gate = "checking" => ~RootShown
=============================================================================
