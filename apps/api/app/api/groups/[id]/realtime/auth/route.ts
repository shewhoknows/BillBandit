import { NextRequest, NextResponse } from 'next/server'
import { requireSettlementUserId } from '@/lib/settlement/route-auth'
import { resolveCallerAccess } from '@/lib/settlement/commands/core'
import { validateRealtimeChannelAccess } from '@/lib/settlement/outbox/auth'
import {
  authorizePrivateChannel,
  isRealtimeAvailable,
} from '@/lib/settlement/outbox/pusher'
import { prisma } from '@/lib/prisma'

export async function POST(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { userId, response } = await requireSettlementUserId(req)
  if (response) return response

  if (!isRealtimeAvailable()) {
    return NextResponse.json({ error: 'Realtime unavailable', available: false }, { status: 503 })
  }

  const body = await req.json()
  const channelName = body.channel_name as string | undefined
  const socketId = body.socket_id as string | undefined
  if (!channelName || !socketId) {
    return NextResponse.json({ error: 'socket_id and channel_name required' }, { status: 400 })
  }

  const access = await resolveCallerAccess(params.id, userId!, prisma)
  const validation = validateRealtimeChannelAccess(params.id, channelName, access)
  if (!validation.ok) {
    return NextResponse.json({ error: validation.error }, { status: validation.status })
  }

  const authResponse = authorizePrivateChannel(socketId, channelName)
  return NextResponse.json({ ...authResponse, available: true })
}
