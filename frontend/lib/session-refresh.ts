// Sunucu tarafı (proxy.ts) oturum yenileme yardımcıları -- Next'e bağımlılığı
// YOK ki node --test ile doğrudan test edilebilsin (bkz. session-refresh.test.mts).
//
// Neden var: access token 15 dk, refresh token 30 gün yaşar (backend
// auth_handler.go). Access çerezi düştüğünde tarayıcıdaki istemci istekleri
// (lib/api.ts fetchWithSession) zaten yenileniyordu; ama sayfa geçişleri ve
// Server Component'ler (apiServer) yenilemiyordu -- 15 dk boşta kalan
// kullanıcı, 30 günlük refresh token'ı dururken /giris'e atılıyordu. Yenileme
// artık proxy'de, sayfa render edilmeden ÖNCE yapılır: yeni çift hem
// tarayıcıya (Set-Cookie) hem aynı isteğin Server Component'lerine (istek
// Cookie başlığı) iletilir.

export const ACCESS_COOKIE = "access_token";
export const REFRESH_COOKIE = "refresh_token";
export const REFRESH_PATH = "/api/v1/auth/refresh";

/** Süresi bu kadar içinde dolacak access token da yenilenir (render ortasında düşmesin). */
export const ACCESS_REFRESH_LEEWAY_MS = 30_000;

/** Tamamlanmış başarılı bir refresh'in aynı (eski) refresh token'la gelen isteklerle paylaşıldığı süre. */
export const REFRESH_GRACE_MS = 20_000;

const REFRESH_TIMEOUT_MS = 5_000;

/** JWT gövdesini İMZA DOĞRULAMADAN okur -- yalnızca UX kararları için (rol yönlendirmesi, süre). */
export function decodeJwtPayload(token: string): Record<string, unknown> | null {
  try {
    const part = token.split(".")[1];
    if (!part) return null;
    const json: unknown = JSON.parse(Buffer.from(part, "base64url").toString("utf-8"));
    return json && typeof json === "object" ? (json as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export type AccessTokenState = "missing" | "fresh" | "expiring" | "expired";

/**
 * missing: çerez yok. expired: süresi geçmiş ya da okunamıyor (kullanılamaz).
 * expiring: hâlâ geçerli ama leeway içinde dolacak. fresh: dokunma.
 * exp claim'i yoksa "fresh" sayılır -- karar backend'indir; burada "her
 * istekte yenile" döngüsü üretmemek daha önemli.
 */
export function accessTokenState(
  token: string | undefined,
  nowMs: number,
  leewayMs: number = ACCESS_REFRESH_LEEWAY_MS
): AccessTokenState {
  if (!token) return "missing";
  const payload = decodeJwtPayload(token);
  if (!payload) return "expired";
  const exp = payload.exp;
  if (typeof exp !== "number") return "fresh";
  const expMs = exp * 1000;
  if (expMs <= nowMs) return "expired";
  if (expMs - leewayMs <= nowMs) return "expiring";
  return "fresh";
}

/** Set-Cookie satırlarından bir çerezin değeri ("name=value; Path=/..." -> value). */
export function cookieValueFrom(setCookies: readonly string[], name: string): string | null {
  for (const line of setCookies) {
    const first = line.split(";")[0] ?? "";
    const eq = first.indexOf("=");
    if (eq < 0) continue;
    if (first.slice(0, eq).trim() === name) return first.slice(eq + 1).trim();
  }
  return null;
}

/** İstek Cookie başlığında verilen çerezleri yenileriyle değiştirir (yoksa ekler). */
export function replaceCookies(cookieHeader: string | null, updates: Record<string, string>): string {
  const parts = (cookieHeader ?? "")
    .split(";")
    .map((p) => p.trim())
    .filter((p) => p !== "" && !(p.slice(0, Math.max(p.indexOf("="), 0)).trim() in updates));
  for (const [name, value] of Object.entries(updates)) parts.push(`${name}=${value}`);
  return parts.join("; ");
}

export type RefreshResult =
  | { ok: true; accessToken: string; refreshToken: string; setCookies: string[] }
  // status null: ağ hatası/zaman aşımı. setCookies: backend'in (varsa)
  // çerez temizleyen Set-Cookie'leri -- iletilip iletilmeyeceğine çağıran
  // karar verir (yarışı kaybeden bir refresh, kazananın yeni çiftini
  // silmemeli).
  | { ok: false; status: number | null; setCookies: string[] };

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

/** Backend refresh ucunu verilen refresh token'la çağırır. Asla throw etmez. */
export async function requestRefresh(
  apiBase: string,
  refreshToken: string,
  fetchImpl: FetchLike = fetch
): Promise<RefreshResult> {
  try {
    const res = await fetchImpl(`${apiBase}${REFRESH_PATH}`, {
      method: "POST",
      headers: { Cookie: `${REFRESH_COOKIE}=${refreshToken}` },
      cache: "no-store",
      redirect: "manual",
      signal: AbortSignal.timeout(REFRESH_TIMEOUT_MS),
    });
    const setCookies = res.headers.getSetCookie();
    if (!res.ok) return { ok: false, status: res.status, setCookies };
    const accessToken = cookieValueFrom(setCookies, ACCESS_COOKIE);
    const newRefresh = cookieValueFrom(setCookies, REFRESH_COOKIE);
    if (!accessToken || !newRefresh) return { ok: false, status: null, setCookies: [] };
    return { ok: true, accessToken, refreshToken: newRefresh, setCookies };
  } catch {
    return { ok: false, status: null, setCookies: [] };
  }
}

/**
 * Refresh token'ı tek kullanımlıktır (rotasyon): aynı token'la iki paralel
 * refresh'ten ikincisi 401 alır. Bir sayfa açılışı aynı anda birden çok
 * istek getirir (belge + RSC + prefetch'ler), hepsi aynı eski token'la.
 * Bu yüzden aynı token için tek uçuş: eşzamanlı çağrılar aynı sonucu
 * paylaşır, başarılı sonuç graceMs boyunca saklanır (yeni çerezler tarayıcıya
 * ulaşmadan yola çıkmış istekler de aynı yeni çifti alır). Başarısız sonuç
 * saklanmaz -- bir sonraki istek yeniden dener.
 */
export function createRefreshCoordinator(opts: {
  refresh: (refreshToken: string) => Promise<RefreshResult>;
  graceMs?: number;
  now?: () => number;
}): (refreshToken: string) => Promise<RefreshResult> {
  const graceMs = opts.graceMs ?? REFRESH_GRACE_MS;
  const now = opts.now ?? Date.now;
  const entries = new Map<string, { promise: Promise<RefreshResult>; settledAt: number | null }>();

  return (refreshToken) => {
    const t = now();
    for (const [key, entry] of entries) {
      if (entry.settledAt !== null && t - entry.settledAt > graceMs) entries.delete(key);
    }
    const existing = entries.get(refreshToken);
    if (existing) return existing.promise;

    const entry: { promise: Promise<RefreshResult>; settledAt: number | null } = {
      promise: Promise.resolve({ ok: false, status: null, setCookies: [] }),
      settledAt: null,
    };
    entry.promise = opts.refresh(refreshToken).then((result) => {
      if (result.ok) entry.settledAt = now();
      else entries.delete(refreshToken);
      return result;
    });
    entries.set(refreshToken, entry);
    return entry.promise;
  };
}
