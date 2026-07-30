# Lock Railway and CI cutover sequence

Type: grilling
Status: resolved
Blocked by: 02, 04

## Question

Exact steps and order for pointing Railway + GitHub Actions at BillBandit `main`, freezing FairShare deploys, and what “verify” means before archive.

## Answer

(Round 3)

1. Land `apps/api` on BillBandit + GitHub Actions deploy workflow  
2. Point Railway service at BillBandit `main` (same DB/env/hostname)  
3. Disable FairShare → Railway deploy  
4. **Verify:** `/api/health` 200; `/api/groups/test/settle-up` 401; SIWA + username on both sims; Shared Settle Up load + one mutation on LiveSettle-Test  
5. Archive FairShare GitHub repo (read-only)
