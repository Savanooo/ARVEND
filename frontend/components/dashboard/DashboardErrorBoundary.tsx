"use client";

import { catchError } from "next/error";

// DashboardBody'nin render güvencesi (D9 "asla fırlatmaz"). Yanıt
// normalizeDashboard'da denetlense de, akış (Suspense) içinde bir kartın
// render'ı yine de hata verirse -- Server Component'te ya da tarayıcıda
// (ör. hydration sonrası) -- sayfa "Application error" ile düşmez; sunucuda
// hazır çizilmiş "Özet yüklenemedi" + Kısayollar gösterilir. Hata durumu,
// DashboardBody'nin verdiği key (generated_at) yeni veriyle değişince
// ("Tekrar dene" -> router.refresh) sıfırlanır.
function DashboardErrorFallback(props: { fallback: React.ReactNode }) {
  return props.fallback;
}

export const DashboardErrorBoundary = catchError(DashboardErrorFallback);
