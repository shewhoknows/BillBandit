# Decide transfer explanation endpoint

Type: grilling
Status: resolved
Blocked by: 02

## Question

BillBandit iOS calls `GET .../settle-up/transfers/:id/explanation` but FairShare never implemented it. Implement during the move, stub gracefully, or drop the client call?

## Answer

(Round 3)

**Stub gracefully** for the move (client already handles failure). Real explanation endpoint is a later ticket, not a cutover blocker.
