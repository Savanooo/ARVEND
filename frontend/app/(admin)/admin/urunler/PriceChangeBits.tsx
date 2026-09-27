import { Badge } from "@/components/ui/Badge";
import { changeTone, formatChangePercent, type ChangeTone } from "@/lib/price-changes";
import { sourceLabels } from "@/lib/price-sources";

// Ürünler, ürün detayı ve Zam Geçmişi'nin ortak küçük parçaları (Server
// Component'lerde de kullanılabilir -- durum/olay dinleyicisi yok).

// Zam müşteri için maliyet artışıdır: tehlike tonu; indirim başarı tonu.
// Renk tek başına taşımaz, metinde her zaman ↑/↓ ya da +/− de vardır.
export const CHANGE_TONE_CLASS: Record<ChangeTone, string> = {
  up: "text-danger",
  down: "text-success",
  flat: "text-text-muted",
};

export function changeToneClass(oldPrice: number, newPrice: number): string {
  return CHANGE_TONE_CLASS[changeTone(oldPrice, newPrice)];
}

/** Tedarikçi rozeti: "Ulaş", "Demir Profil". */
export function SourceBadge({ source, name }: { source: string; name?: string }) {
  // İki kelimelik ad ("Demir Profil") dar tablo hücresinde iki satıra bölünmesin.
  return (
    <Badge tone="info">
      <span className="whitespace-nowrap">{sourceLabels(source, name).short}</span>
    </Badge>
  );
}

/**
 * "↑ %3,25" (zam) / "↓ %2,1" (indirim); yüzde tanımsızsa "—". Renk de ok
 * da fiyatların yönünden gelir (%0'a yuvarlanan zam da "↑ <%0,01").
 */
export function ChangePercent({
  oldPrice,
  newPrice,
  percent,
  className = "",
}: {
  oldPrice: number;
  newPrice: number;
  percent: number | null;
  className?: string;
}) {
  const tone = changeTone(oldPrice, newPrice);
  return (
    <span className={`whitespace-nowrap font-semibold ${CHANGE_TONE_CLASS[tone]} ${className}`}>
      {formatChangePercent(percent, tone)}
    </span>
  );
}
