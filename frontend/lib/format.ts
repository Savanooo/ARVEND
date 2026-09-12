export function formatTL(value: number): string {
  return (
    value.toLocaleString("tr-TR", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }) + " TL"
  );
}

const CURRENCY_SUFFIX: Record<string, string> = { TRY: "TL", USD: "$", EUR: "€" };

// formatMoney, tutarı projenin para birimine göre biçimler -- finans
// ekranlarında her zaman bu kullanılmalı (formatTL yalnızca TL'ye sabittir).
export function formatMoney(value: number, currency = "TRY"): string {
  const amount = value.toLocaleString("tr-TR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  return `${amount} ${CURRENCY_SUFFIX[currency] ?? currency}`;
}
