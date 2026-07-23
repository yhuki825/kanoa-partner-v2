// Edge Functions 共通ユーティリティ
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SignJWT, jwtVerify } from "https://esm.sh/jose@5";

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

function jwtSecret(): Uint8Array {
  const s = Deno.env.get("JWT_SECRET") ?? Deno.env.get("SUPABASE_JWT_SECRET");
  if (!s) throw new Error("JWT_SECRET not configured");
  return new TextEncoder().encode(s);
}

// パートナーJWTの発行（PostgRESTが受理する形式: role=authenticated 固定）
export async function signPartnerJwt(company: { id: string; tier: number; code: string }) {
  return await new SignJWT({
    role: "authenticated",
    app_role: "partner",
    company_id: company.id,
    tier: company.tier,
    code: company.code,
  })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setAudience("authenticated")
    .setIssuedAt()
    .setExpirationTime("12h")
    .sign(jwtSecret());
}

// Authorizationヘッダの検証。パートナーなら claims を、管理者JWTなら user id を返す
export async function callerFromAuth(req: Request): Promise<
  | { kind: "partner"; companyId: string; tier: number }
  | { kind: "admin"; userId: string }
  | null
> {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, jwtSecret());
    if (payload.app_role === "partner" && typeof payload.company_id === "string") {
      return { kind: "partner", companyId: payload.company_id, tier: Number(payload.tier ?? 0) };
    }
    if (typeof payload.sub === "string") {
      // supabase.auth のユーザー → kanoa_admins_v2 登録者のみ管理者
      const sb = serviceClient();
      const { data } = await sb.from("kanoa_admins_v2").select("user_id").eq("user_id", payload.sub).maybeSingle();
      if (data) return { kind: "admin", userId: payload.sub };
    }
  } catch (_e) { /* 署名不正・期限切れ */ }
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
