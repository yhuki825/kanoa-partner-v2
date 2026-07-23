// Edge Functions 共通ユーティリティ
// パートナー認証: 企業ごとに Supabase Auth ユーザーを持ち、code+pw 照合成功時に
// そのユーザーのセッション（access/refresh トークン）を発行して返す。
// 自前のJWT署名は行わない（署名鍵の管理が不要で、鍵ローテーションにも自動追従）。
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

// service_role クライアント（RLSを通さない。EF内でのみ使用）
export function serviceClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
}

// 企業コード→内部メールアドレス（authユーザーの識別子。実在のメールではない）
export function partnerEmail(code: string): string {
  return `${code.toLowerCase()}@partners.kanoa-portal.invalid`;
}

// 企業に紐づく auth ユーザーを用意し、セッション（access/refresh）を発行する
export async function sessionForCompany(company: {
  id: string; tier: number; code: string; auth_user_id?: string | null;
}): Promise<{ access_token: string; refresh_token: string }> {
  const sb = serviceClient();
  const email = partnerEmail(company.code);
  const meta = { app_role: "partner", company_id: company.id, tier: company.tier, code: company.code };

  // 1) authユーザーを取得 or 作成（app_metadataは毎回同期）
  let userId = company.auth_user_id ?? null;
  if (!userId) {
    const { data: created, error } = await sb.auth.admin.createUser({
      email, email_confirm: true, app_metadata: meta,
    });
    if (error && !`${error.message}`.includes("already")) throw error;
    if (created?.user) userId = created.user.id;
    if (!userId) {
      // 既存ユーザー（過去の作成分）をメールで検索
      const { data: list } = await sb.auth.admin.listUsers({ page: 1, perPage: 1000 });
      userId = list?.users?.find((u) => u.email === email)?.id ?? null;
    }
    if (!userId) throw new Error("auth user unavailable");
    await sb.from("companies").update({ auth_user_id: userId }).eq("id", company.id);
  }
  await sb.auth.admin.updateUserById(userId, { app_metadata: meta });

  // 2) マジックリンクを内部発行し、そのまま検証してセッションを得る（メールは送らない）
  const { data: link, error: linkErr } = await sb.auth.admin.generateLink({ type: "magiclink", email });
  if (linkErr || !link?.properties?.hashed_token) throw linkErr ?? new Error("link generation failed");

  const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
    { auth: { persistSession: false } });
  const { data: sess, error: otpErr } = await anon.auth.verifyOtp({
    type: "magiclink", token_hash: link.properties.hashed_token,
  });
  if (otpErr || !sess?.session) throw otpErr ?? new Error("session issue failed");
  return { access_token: sess.session.access_token, refresh_token: sess.session.refresh_token };
}

// Authorizationヘッダの検証（Supabase Auth のトークンとして検証）
export async function callerFromAuth(req: Request): Promise<
  | { kind: "partner"; companyId: string; tier: number }
  | { kind: "admin"; userId: string }
  | null
> {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const sb = serviceClient();
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data?.user) return null;
  const meta = (data.user.app_metadata ?? {}) as Record<string, unknown>;
  if (meta.app_role === "partner" && typeof meta.company_id === "string") {
    return { kind: "partner", companyId: meta.company_id, tier: Number(meta.tier ?? 0) };
  }
  const { data: adm } = await sb.from("kanoa_admins_v2").select("user_id").eq("user_id", data.user.id).maybeSingle();
  if (adm) return { kind: "admin", userId: data.user.id };
  return null;
}

// V1互換のレガシーハッシュ（SHA-256固定salt）。移行ユーザーの初回照合にのみ使用
export async function legacyHash(plain: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("kanoa_salt_2026::" + plain));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// 読み間違えにくい一時パスワード（0/O/1/l/I を除外）
export function genTempPassword(len = 12): string {
  const chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789";
  const rnd = crypto.getRandomValues(new Uint32Array(len));
  return Array.from(rnd, (n) => chars[n % chars.length]).join("");
}
