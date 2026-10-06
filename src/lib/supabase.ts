import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined
export const configured = Boolean(url && key)
export const supabase = configured ? createClient(url!, key!, {
  auth: { persistSession: true, autoRefreshToken: true },
  realtime: { params: { eventsPerSecond: 10 } },
}) : null

export type Player = { id: string; name: string; character: string; color: string; joined_at: string; solved?: boolean; rank?: number; elapsed_ms?: number; attempts_count?: number; points?: number; total_points?: number }
export type GameState = { game: { id: string; code: string; title: string; status: 'lobby'|'running'|'paused'|'finished'; current_round: number; settings: { cooldown_seconds?: number; max_attempts?: number; late_join?: boolean; letter_feedback?: boolean; total_rounds?:number; lock_room?:boolean }; lock_room?: boolean }; round: { round_number: number; prompt: string; hints: string[]; revealed_hints: number; status: string; started_at: string|null; ended_at: string|null; time_limit_seconds: number|null }|null; players: Player[]; leaderboard: Player[]; attempts_total: number; solved_count: number }

export async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  if (!supabase) throw new Error('Configure VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY para conectar ao Supabase.')
  const { data, error } = await supabase.rpc(name, args)
  if (error) throw error
  return data as T
}
