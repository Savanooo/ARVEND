import type { ApiErrorBody } from "./types";

/** Tarayıcının ulaştığı public API kökü (build zamanında gömülür). */
export const API_BASE =
  process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8080";

/**
 * Next.js sunucu sürecinin ulaştığı API kökü. Production'da Go API ile aynı
 * makinede olduğundan Cloudflare'a çıkmadan doğrudan loopback'e gider;
 * tanımlı değilse public köke düşer. Server-only env olduğu için tarayıcı
 * bundle'ına girmez -- çağrı anında okunur. proxy.ts'in oturum yenilemesi de
 * bunu kullanır.
 */
export function internalApiBase(): string {
  return process.env.INTERNAL_API_URL || API_BASE;
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

// Gövde JSON değilse (ör. gateway'in 502 HTML sayfası, düz metin hata)
// undefined -- JSON.parse'ın SyntaxError'ı ApiError yerine çağırana
// sızıp "Bağlantı hatası"/çökmüş sayfa olarak görünmesin.
function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

async function parse<T>(res: Response): Promise<T> {
  const text = await res.text();
  const body = text ? parseJson(text) : null;
  if (!res.ok) {
    const message =
      (body as ApiErrorBody | null | undefined)?.error ??
      (res.status >= 500 ? "Sunucuya şu an ulaşılamıyor, lütfen biraz sonra tekrar deneyin." : "Beklenmeyen bir hata oluştu");
    throw new ApiError(res.status, message);
  }
  if (body === undefined) throw new ApiError(res.status, "Sunucudan beklenmeyen bir yanıt alındı");
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

// unauthorized: refresh 401 (token geçersiz -- ya da başka bir sekme/istek
// onu az önce harcadı). forbidden: 403 (pasif kullanıcı / askıdaki firma),
// kesin red.
type RefreshOutcome = "ok" | "unauthorized" | "forbidden" | "error";

let refreshInFlight: Promise<RefreshOutcome> | null = null;

// Sekmeler arası koordinasyon. Çerezler sekmeler arasında ORTAKTIR ama
// refreshInFlight sekme başınadır: iki sekme aynı anda 401 alıp aynı tek
// kullanımlık refresh token'ı harcarsa kaybedenin 401 yanıtı çerezleri
// siler ve her sekme düşer. Web Locks ile refresh'ler sekmeler arasında
// sıraya girer; kilidi alan sekme, başka bir sekme isteği gönderildikten
// SONRA zaten yenilediyse ikinci kez refresh çağırmaz, yalnızca isteği
// tekrarlar.
const REFRESH_LOCK = "arvend:session-refresh";
const REFRESHED_AT_KEY = "arvend:session-refreshed-at";

function readRefreshedAt(): number {
  try {
    return Number(window.localStorage?.getItem(REFRESHED_AT_KEY)) || 0;
  } catch {
    return 0;
  }
}

function markRefreshed(): void {
  try {
    window.localStorage?.setItem(REFRESHED_AT_KEY, String(Date.now()));
  } catch {
    // Gizli mod / engelli depolama: kilit yine sıraya sokar, yalnızca
    // gereksiz bir refresh atlanamaz.
  }
}

function withRefreshLock(fn: () => Promise<RefreshOutcome>): Promise<RefreshOutcome> {
  const locks = typeof navigator === "undefined" ? undefined : navigator.locks;
  if (!locks?.request) return fn();
  // Kilit, geri çağrının promise'i bitene (refresh tamamlanana) kadar tutulur.
  return new Promise<RefreshOutcome>((resolve) => {
    locks
      .request(REFRESH_LOCK, async () => {
        resolve(await fn());
      })
      .catch(() => resolve("error"));
  });
}

/**
 * Tek uçuş (single-flight) refresh: eşzamanlı 401 alan istekler aynı refresh
 * çağrısını paylaşır. Backend refresh token'ı rotasyonla TEK KULLANIMLIK
 * verdiği için paralel iki refresh'in ikincisi 401 alır ve cookie'leri siler;
 * tek uçuş (sekme içi) + Web Locks (sekmeler arası) bu yüzden şarttır.
 * Refresh token JS'e hiç çıkmaz: HttpOnly cookie, credentials: "include" ile
 * taşınır, yeni çift Set-Cookie ile gelir. sentAt: 401 alan isteğin
 * gönderildiği an.
 */
function refreshSession(sentAt: number): Promise<RefreshOutcome> {
  if (!refreshInFlight) {
    refreshInFlight = withRefreshLock(async () => {
      if (readRefreshedAt() > sentAt) return "ok";
      const outcome = await fetch(`${API_BASE}/api/v1/auth/refresh`, {
        method: "POST",
        credentials: "include",
      })
        .then((res): RefreshOutcome => {
          if (res.ok) return "ok";
          if (res.status === 401) return "unauthorized";
          return res.status === 403 ? "forbidden" : "error";
        })
        .catch((): RefreshOutcome => "error");
      if (outcome === "ok") markRefreshed();
      return outcome;
    }).finally(() => {
      refreshInFlight = null;
    });
  }
  return refreshInFlight;
}

function redirectToLogin(): void {
  if (typeof window === "undefined" || window.location.pathname === "/giris") return;
  // Giriş sonrası kullanıcı kaldığı sayfaya döner (bkz. safeNextPath).
  const here = `${window.location.pathname}${window.location.search ?? ""}`;
  // Bilinçli tam sayfa navigasyon: oturum düştüğünde client state ve router
  // cache'i (yetkili sayfaların RSC payload'ları) temizlenmeli; bu modül
  // React'e bağlı değil (useRouter yok) ve basePath kullanılmıyor.
  // eslint-disable-next-line @next/next/no-location-assign-relative-destination
  window.location.assign(`/giris?next=${encodeURIComponent(here)}`);
}

/**
 * Tarayıcı fetch'i + oturum yenileme. İstek 401 dönerse refresh BİR kez
 * denenir (tek uçuş); başarılıysa orijinal istek BİR kez tekrarlanır ve
 * tekrar da 401 dönerse yeni bir refresh başlatılmaz. Refresh 401 verirse
 * istek yine BİR kez tekrarlanır: çerezler o arada başka bir sekme ya da
 * sunucu tarafı (proxy.ts) yenilemesiyle tazelenmiş olabilir -- ancak o da
 * 401 dönerse /giris'e yönlendirilir. Refresh 403 verirse doğrudan /giris;
 * ağ hatası/5xx verirse yönlendirme yapılmaz, orijinal 401 çağırana döner
 * (geçici bir kesintide oturumu düşürmemek için). Her durumda son yanıt
 * döner; JSON çağrılarında parse() bunu ApiError'a çevirir.
 */
export async function fetchWithSession(
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const send = () => fetch(`${API_BASE}${path}`, { ...init, credentials: "include" });

  const sentAt = Date.now();
  const res = await send();
  if (res.status !== 401 || NO_REFRESH_PATHS.has(path.split("?")[0])) return res;

  const outcome = await refreshSession(sentAt);
  if (outcome === "error") return res;
  if (outcome === "forbidden") {
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
 * token ise iptal edilmiş olurdu (oturum düşer). Yenileme bir adım önce,
 * proxy.ts'te yapılır: access çerezi yoksa/dolmuşsa proxy refresh eder ve
 * yeni çifti hem tarayıcıya hem bu isteğin Cookie başlığına koyar -- yani
 * buraya gelen cookieHeader zaten taze. Tarayıcı içi istekler (apiClient)
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
