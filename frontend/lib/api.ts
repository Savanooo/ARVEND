import type { ApiErrorBody } from "./types";

export const API_BASE =
  process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8080";

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

/**
 * Tarayıcıda (Client Component) çalışır — cookie'ler otomatik gider
 * (`credentials: 'include'`), backend'in Set-Cookie'si de otomatik saklanır.
 */
export async function apiClient<T>(
  path: string,
  options: RequestInit = {}
): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    credentials: "include",
    headers: { "Content-Type": "application/json", ...options.headers },
  });
  return parse<T>(res);
}

/**
 * Server Component'te çalışır. Sunucudan sunucuya yapılan fetch'in kendi
 * tarayıcı çerez kavanozu olmadığından, gelen isteğin cookie'lerini elle
 * ilettiği için `cookieHeader` parametresi alır (bkz. lib/auth.ts).
 */
export async function apiServer<T>(
  path: string,
  cookieHeader: string,
  options: RequestInit = {}
): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
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
