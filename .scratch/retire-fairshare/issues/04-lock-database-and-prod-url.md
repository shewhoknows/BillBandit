# Lock database and production URL ownership

Type: grilling
Status: resolved
Blocked by: 01

## Question

Do we keep the existing Railway Postgres + `billbandit-api.contenthelper.in` hostname (only change which repo deploys), or provision a new DB/URL as part of the move?

## Answer

(Round 2)

Keep the **same** Railway Postgres and hostname `https://billbandit-api.contenthelper.in`. Only change which GitHub repo/CI deploys the service. No new database.
