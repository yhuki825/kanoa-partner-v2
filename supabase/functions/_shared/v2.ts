// V2 Edge Functions 共通（V1と同じSupabaseを共有するため、関数名はすべて v2- 接頭辞）
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

export function admin() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } });
}

// CAのログインID → ログイン用の内部メール（画面には出さない）
// V1は partner.kanoa.local、旧V2試作は partners.kanoa-portal.invalid を使っていたため別ドメインにする
export function loginEmail(loginId: string): string {
  return `${loginId.toLowerCase()}@id.kanoa-portal.invalid`;
}

export function tempPassword(len = 12): string {
  const chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"; // 0/O/1/l/I を除外
  const r = crypto.getRandomValues(new Uint32Array(len));
  return Array.from(r, (n) => chars[n % chars.length]).join("");
}

export type Caller = {
  memberId: string; userId: string; role: "ra" | "ca";
  companyId: string | null; tier: number | null; isOwner: boolean;
};

// Authorizationヘッダの本人を v2_members から特定（停止中の人・会社は不可）
export async function caller(req: Request): Promise<Caller | null> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const sb = admin();
  const { data: u, error } = await sb.auth.getUser(token);
  if (error || !u?.user) return null;
  const { data: m } = await sb.from("v2_members")
    .select("id, role, company_id, is_owner, status, v2_companies!v2_members_company_id_fkey(tier, status)")
    .eq("user_id", u.user.id).maybeSingle();
  if (!m || m.status !== "active") return null;
  // deno-lint-ignore no-explicit-any
  const comp = (m as any).v2_companies;
  if (m.role === "ca" && (!comp || comp.status !== "active")) return null;
  return {
    memberId: m.id, userId: u.user.id, role: m.role, companyId: m.company_id,
    tier: comp?.tier ?? null, isOwner: !!m.is_owner,
  };
}
