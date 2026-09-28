import type { Tone } from "@/components/ui/Badge";

// Ana sayfanın küçük rozeti (kart dikkat rozeti, Dikkat sayacı, proje
// durumu, okunmamış sayısı). Paylaşılan Badge'le aynı görünüm, iki farkla:
//   - Altın tonda metin altın DEĞİL koyu metindir; altın anlamı küçük bir
//     noktayla taşınır. Spec §5.9: altın (#b8892a) 18px altı metinde
//     kullanılmaz (açık altın zeminde ~2,8:1 kontrast, WCAG AA'nın altında).
//   - Hiç kırılmaz/küçülmez: dar kart başlığında "1 BEKLİYOR" iki satıra
//     bölünmez, yer açılması gerekiyorsa başlık kısalır.
// Badge diğer ekranlarda kullanıldığı için orada değişiklik yapılmadı.
const TONES: Record<Tone, string> = {
  gold: "bg-gold-soft text-text",
  success: "bg-success-soft text-success",
  danger: "bg-danger-soft text-danger",
  muted: "bg-surface-hover text-text-muted",
  info: "bg-info-soft text-info",
};

export function Chip({ tone = "muted", children }: { tone?: Tone; children: React.ReactNode }) {
  return (
    <span
      className={`inline-flex shrink-0 items-center gap-1 rounded-md px-2 py-0.5 text-xs font-semibold uppercase tracking-wide whitespace-nowrap ${TONES[tone]}`}
    >
      {tone === "gold" && <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-gold" />}
      {children}
    </span>
  );
}
