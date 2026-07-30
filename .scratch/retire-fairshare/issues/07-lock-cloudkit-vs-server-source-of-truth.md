# Lock CloudKit vs server group source of truth

Type: grilling
Status: resolved
Blocked by: 02

## Question

After the move, are CloudKit groups still the day-to-day source of truth with optional `serverGroupId` linking, or should mobile group/expense APIs become primary for collaborative groups?

## Answer

(Round 3)

Keep **CloudKit as day-to-day UX**. Mobile group/expense APIs **mirror into Postgres** when a group is linked (`serverGroupId`) so Shared Settle Up has ledger rows. Do not rip out CloudKit in this effort.
