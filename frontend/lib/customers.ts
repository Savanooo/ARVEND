// Müşteri formlarının saf yardımcıları -- node testleri (customers.test.mts)
// içe aktarır. Kaynak: mobil customer.dart DuplicateCustomer ve
// mobile/API_CONTRACT.md "Customers" > "Duplicate guard".

/**
 * 409 `duplicate_customer`: aynı vergi no ya da telefonla kayıtlı müşteri
 * var. Backend çakışanı döner; kullanıcı onu açabilir ya da
 * `allow_duplicate: true` ile yine de kaydedebilir (ör. aynı firmanın iki
 * şubesi tek vergi numarasıyla).
 */
export interface DuplicateCustomer {
  id: string;
  name: string;
  isActive: boolean;
  // "tax_number" | "phone" -- hangi bilgi çakıştı.
  field: string;
  // Sunucunun Türkçe açıklaması (çakışan müşterinin adıyla).
  message: string;
}

/**
 * Hata bir müşteri çakışması değilse null. ApiError'a (lib/api.ts) yapısal
 * bakılır: status 409, code "duplicate_customer" ve gövdede
 * existing_customer.id.
 */
export function duplicateCustomerFromError(err: unknown): DuplicateCustomer | null {
  if (!err || typeof err !== "object") return null;
  const e = err as { status?: unknown; code?: unknown; body?: unknown; message?: unknown };
  if (e.status !== 409 || e.code !== "duplicate_customer") return null;
  const body = (e.body ?? {}) as { field?: unknown; existing_customer?: unknown };
  const existing = body.existing_customer as { id?: unknown; name?: unknown; is_active?: unknown } | undefined;
  if (!existing || typeof existing.id !== "string" || !existing.id) return null;
  return {
    id: existing.id,
    name: typeof existing.name === "string" ? existing.name : "",
    isActive: existing.is_active !== false,
    field: typeof body.field === "string" ? body.field : "",
    message: typeof e.message === "string" ? e.message : "",
  };
}

/** Pencerenin giriş cümlesi (mobil metni). */
export function duplicateCustomerIntro(field: string): string {
  return field === "tax_number"
    ? "Aynı vergi numarasıyla kayıtlı bir müşteri var:"
    : "Aynı telefon numarasıyla kayıtlı bir müşteri var:";
}
