import { notFound } from "next/navigation";

import { ApiError } from "./api";

/**
 * Detay sayfalarının ana kaydı için: backend 404 (kayıt silinmiş ya da hiç
 * yok) Next'in not-found sayfasına çevrilir. Bayat bir bağlantı (ör.
 * silinmiş bir teklifin bildirimi) böylece "Application error" yerine
 * "Kayıt bulunamadı" gösterir. Diğer hatalar (403, 5xx) olduğu gibi
 * yükselir. Yalnızca Server Component'lerde kullanılır.
 */
export async function orNotFound<T>(promise: Promise<T>): Promise<T> {
  try {
    return await promise;
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) notFound();
    throw err;
  }
}
