import type { DashboardResponse } from "@/lib/dashboard";
import { canAccess } from "@/lib/permissions";
import type { User } from "@/lib/types";

// Modül kartlarına geçen ortak bağlam (Server Component'ler arasında).
export interface CardContext {
  data: DashboardResponse;
  // YALNIZCA boş durum CTA'larının yazma izni kontrolü için (spec D2) --
  // kartın/alt bloğun görünürlüğüne sunucu karar verir.
  user: User;
  // Görevlerim üst satıra taşındıysa Görevler kartı listesini gizler.
  promotedMyTasks: boolean;
  // Dikkat paneli görünüyor mu (kurulum modunda gizli): kart alt satırı
  // çok kayıtlı grupta panele (#dikkat-...) ya da modül sayfasına gider.
  dikkatVisible: boolean;
}

/** Tüm yazma izinleri var mı (Yönetici'ye kilitli izinlerde kaba rolü de ister). */
export function canAll(ctx: CardContext, codes: readonly string[]): boolean {
  return codes.every((code) => canAccess(ctx.user, code));
}
