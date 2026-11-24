FROM oven/bun:1.3.14-alpine AS bun

FROM node:20-alpine AS base

# Install dependencies for Prisma binary engine
RUN apk add --no-cache libc6-compat openssl
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun

WORKDIR /app

# ── Install dependencies ──────────────────────────────────────────────────────
FROM base AS deps
COPY package.json bun.lock ./
COPY apps/api/package.json ./apps/api/package.json
# Skip postinstall (prisma generate) during install; we run it explicitly
RUN bun install --frozen-lockfile --ignore-scripts

# ── Build ─────────────────────────────────────────────────────────────────────
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Generate Prisma client
RUN bun run db:generate

# Ensure public dir exists (may be empty)
RUN mkdir -p /app/apps/api/public

# Build Next.js
ENV NEXT_TELEMETRY_DISABLED=1
RUN bun run build

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
COPY --from=builder /app/apps/api/package.json ./apps/api/package.json
COPY --from=builder /app/apps/api/prisma ./apps/api/prisma

USER nextjs

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

# Migrate, then start. A failed migration must stop the
# container so the health check cannot accept an app with an old schema.
CMD ["sh", "-c", "bun run db:migrate && exec bun run start"]
