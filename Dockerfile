FROM node:20-alpine AS base

# Install dependencies for Prisma binary engine
RUN apk add --no-cache libc6-compat openssl

WORKDIR /app

# ── Install dependencies ──────────────────────────────────────────────────────
FROM base AS deps
COPY package.json package-lock.json ./
COPY apps/api/package.json ./apps/api/package.json
# Skip postinstall (prisma generate) during install; we run it explicitly
RUN npm ci --ignore-scripts

# ── Build ─────────────────────────────────────────────────────────────────────
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Generate Prisma client
RUN npx prisma generate --schema apps/api/prisma/schema.prisma

# Ensure public dir exists (may be empty)
RUN mkdir -p /app/apps/api/public

# Build Next.js
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ── Production runner ─────────────────────────────────────────────────────────
FROM base AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# Copy public assets
COPY --from=builder /app/apps/api/public ./apps/api/public

# Copy Next.js build output (standalone mode not enabled, so copy full .next)
COPY --from=builder /app/apps/api/.next ./apps/api/.next
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/package-lock.json ./package-lock.json
COPY --from=builder /app/apps/api/package.json ./apps/api/package.json
COPY --from=builder /app/apps/api/prisma ./apps/api/prisma

USER nextjs

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

# Migrate, optionally seed, then start
CMD ["sh", "-c", "npx prisma migrate deploy --schema apps/api/prisma/schema.prisma && [ \"$SEED_ON_START\" = 'true' ] && npm run db:seed; npm run start"]
