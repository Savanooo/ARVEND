// Ortak sınıf dizeleri (Tailwind bu dosyayı da tarar). Bileşen değil, saf
// sabit -- Server ve Client Component'ler içe aktarabilir.

// Klavye odağı: her etkileşimli ana sayfa öğesinde görünür altın halka.
export const FOCUS_RING = "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gold";

// Evin etiket stili (CardHeader, Th, form etiketleri, KPI etiketleri).
export const LABEL = "text-xs font-semibold uppercase tracking-widest text-text-muted";

// Button.tsx ile aynı görünüm -- bağlantıyı (<Link>) buton gibi göstermek
// için; <a> içine <button> sarmak geçersiz iç içe etkileşim olurdu.
// aria-disabled: iş sürerken odağı koruyan "meşgul" düğmeler (native
// disabled odaktaki düğmeden klavye odağını düşürür).
const BUTTON_BASE =
  "items-center justify-center gap-2 rounded-md text-sm font-medium whitespace-nowrap transition-colors disabled:cursor-not-allowed disabled:opacity-50 aria-disabled:cursor-progress aria-disabled:opacity-50";

const BUTTON_VARIANTS = {
  primary: "bg-gold text-text hover:bg-gold-hover",
  secondary: "border border-border bg-surface text-text hover:bg-surface-hover",
  ghost: "text-text-muted hover:bg-surface-hover hover:text-text",
} as const;

export type ButtonLookVariant = keyof typeof BUTTON_VARIANTS;

// display: görünürlük sınıfları (ör. "hidden @2xl:inline-flex") -- çakışan
// iki display utility'si aynı öğede olmasın diye tabana konmaz.
export function buttonClass(variant: ButtonLookVariant, size: "md" | "sm" = "md", display = "inline-flex"): string {
  const pad = size === "sm" ? "px-3 py-1.5 text-xs" : "px-4 py-2";
  return `${display} ${BUTTON_BASE} ${pad} ${BUTTON_VARIANTS[variant]} ${FOCUS_RING}`;
}
