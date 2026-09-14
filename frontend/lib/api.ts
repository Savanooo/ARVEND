import type { ApiErrorBody } from "./types";

/** Tarayıcının ulaştığı public API kökü (build zamanında gömülür). */
export const API_BASE =
  process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8080";

/**
 * Next.js sunucu sürecinin ulaştığı API kökü. Production'da Go API ile aynı
 * makinede olduğundan Cloudflare'a çıkmadan doğrudan loopback'e gider;
 * tanımlı değilse public köke düşer. Server-only env olduğu için tarayıcı
 * bundle'ına girmez -- çağrı anında okunur.
 */
function internalApiBase(): string {
  return process.env.INTERNAL_API_URL || API_BASE;
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function parse<T>(res: Response): Promise<T> {
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const message = (body as ApiErrorBody | null)?.error ?? "Beklenmeyen bir hata oluştu";
    throw new ApiError(res.status, message);
  }
  return body as T;
}

// ---------------------------------------------------------------------------
// Oturum yenileme (yalnızca tarayıcı)
// ---------------------------------------------------------------------------

/**
 * 401'i refresh ile kurtarmaya ÇALIŞMAYACAĞIMIZ uçlar: login'de 401 "şifre
 * hatalı" demektir; refresh ve logout ise kendi döngülerine girmemeli.
 */
const NO_REFRESH_PATHS = new Set([
  "/api/v1/auth/login",
  "/api/v1/auth/refresh",
  "/api/v1/auth/logout",
]);

type RefreshOutcome = "ok" | "unauthorized" | "error";

let refreshInFlight: Promise<RefreshOutcome> | null = null;

/**
 * Tek uçuş (single-flight) refresh: eşzamanlı 401 alan istekler aynı refresh
 * çağrısını paylaşır. Backend refresh token'ı rotasyonla TEK KULLANIMLIK
 * verdiği için paralel iki refresh'in ikincisi 401 alır ve cookie'leri siler;
 * tek uçuş bu yüzden şarttır. Refresh token JS'e hiç çıkmaz: HttpOnly cookie,
 * credentials: "include" ile taşınır, yeni çift Set-Cookie ile gelir.
 */
function refreshSession(): Promise<RefreshOutcome> {
  if (!refreshInFlight) {
    refreshInFlight = fetch(`${API_BASE}/api/v1/auth/refresh`, {
      method: "POST",
      credentials: "include",
    })
      .then((res): RefreshOutcome => {
        if (res.ok) return "ok";
        return res.status === 401 || res.status === 403 ? "unauthorized" : "error";
      })
      .catch((): RefreshOutcome => "error")
      .finally(() => {
        refreshInFlight = null;
      });
  }
  return refreshInFlight;
}

function redirectToLogin(): void {
  if (typeof window === "undefined" || window.location.pathname === "/giris") return;
  // Bilinçli tam sayfa navigasyon: oturum düştüğünde client state ve router
  // cache'i (yetkili sayfaların RSC payload'ları) temizlenmeli; bu modül
  // React'e bağlı değil (useRouter yok) ve basePath kullanılmıyor.
  // eslint-disable-next-line @next/next/no-location-assign-relative-destination
  window.location.assign("/giris");
}

/**
 * Tarayıcı fetch'i + oturum yenileme. İstek 401 dönerse refresh BİR kez
 * denenir (tek uçuş); başarılıysa orijinal istek BİR kez tekrarlanır ve
 * tekrar da 401 dönerse yeni bir refresh başlatılmaz. Refresh 401/403
 * verirse (ya da tekrar 401 dönerse) /giris'e yönlendirilir; refresh ağ
 * hatası/5xx verirse yönlendirme yapılmaz, orijinal 401 çağırana döner
 * (geçici bir kesintide oturumu düşürmemek için). Her durumda son yanıt
 * döner; JSON çağrılarında parse() bunu ApiError'a çevirir.
 */
export async function fetchWithSession(
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const send = () => fetch(`${API_BASE}${path}`, { ...init, credentials: "include" });

  const res = await send();
  if (res.status !== 401 || NO_REFRESH_PATHS.has(path.split("?")[0])) return res;

  const outcome = await refreshSession();
  if (outcome === "error") return res;
  if (outcome === "unauthorized") {
    redirectToLogin();
    return res;
  }

  const retried = await send();
  if (retried.status === 401) redirectToLogin();
  return retried;
}

/**
 * Tarayıcıda (Client Component) çalışır — cookie'ler otomatik gider
 * (`credentials: 'include'`), backend'in Set-Cookie'si de otomatik saklanır.
 * 401'de fetchWithSession üzerinden oturum yenilenir.
 */
export async function apiClient<T>(
  path: string,
  options: RequestInit = {}
): Promise<T> {
  const res = await fetchWithSession(path, {
    ...options,
    headers: { "Content-Type": "application/json", ...options.headers },
  });
  return parse<T>(res);
}

/**
 * Server Component'te çalışır. Sunucudan sunucuya yapılan fetch'in kendi
 * tarayıcı çerez kavanozu olmadığından, gelen isteğin cookie'lerini elle
 * ilettiği için `cookieHeader` parametresi alır (bkz. lib/auth.ts).
 *
 * Oturum YENİLEMEZ -- bilinçli olarak: backend refresh token'ı rotasyonla tek
 * kullanımlık verir ve bir Server Component yanıta Set-Cookie yazamaz. Burada
 * refresh yapılsaydı yeni çift tarayıcıya ulaşmaz, tarayıcıdaki eski refresh
 * token ise iptal edilmiş olurdu (oturum düşer). Bu yüzden süresi dolmuş
 * access token'la gelen RSC isteği 401 alır, getCurrentUser null döner ve
 * layout /giris'e yönlendirir. Tarayıcı içi istekler (apiClient) ise
 * fetchWithSession ile yenilenir.
 */
export async function apiServer<T>(
  path: string,
  cookieHeader: string,
  options: RequestInit = {}
): Promise<T> {
  const res = await fetch(`${internalApiBase()}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      Cookie: cookieHeader,
      ...options.headers,
    },
    cache: "no-store",
  });
  return parse<T>(res);
}
