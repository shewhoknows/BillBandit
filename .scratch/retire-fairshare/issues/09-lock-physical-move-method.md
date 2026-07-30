# Lock physical move method

Type: grilling
Status: resolved
Blocked by: 02, 06

## Question

How do we physically bring FairShare `apps/web` code into BillBandit `apps/api` — copy selected trees, git subtree/filter-repo for history, or fresh scaffold + port files?

## Answer

(Round 3)

**Fresh `apps/api` scaffold + copy** the selected FairShare trees (routes/libs/prisma/Dockerfile/deploy). Do not filter-repo whole FairShare history into BillBandit.
