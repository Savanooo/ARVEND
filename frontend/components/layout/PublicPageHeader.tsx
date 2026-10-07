// Müşteriye açık (kimlik doğrulamasız) paylaşım sayfalarının başlığı.
// Eskiden burada platformun logosu ve sabit "Arvend Yapı" yazıyordu -- her
// firmanın müşterisi teklifi başka bir firmadan gelmiş gibi görüyordu.
// Artık teklifi/ek işi gönderen firmanın adı (backend organization_name)
// gösterilir; firmalar için henüz bir logo yükleme/sunma altyapısı
// olmadığından logo yerine adın baş harfi kullanılır. Ad bilinmiyorsa
// (bağlantı geçersiz) yalnızca sayfa başlığı kalır -- hiçbir firma adı
// tahmin edilmez.
export function PublicPageHeader({
  organizationName,
  subtitle,
}: {
  organizationName?: string | null;
  subtitle: string;
}) {
  const name = organizationName?.trim() ?? "";
  const initial = name ? name.charAt(0).toLocaleUpperCase("tr-TR") : "";

  return (
    <div className="flex items-center gap-3">
      {initial && (
        <div
          aria-hidden
          className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md bg-gold-soft text-lg font-bold text-gold"
        >
          {initial}
        </div>
      )}
      <div>
        {name && <div className="font-semibold">{name}</div>}
        <div className={name ? "text-xs text-text-muted" : "font-semibold"}>{subtitle}</div>
      </div>
    </div>
  );
}
