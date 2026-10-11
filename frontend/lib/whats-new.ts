/*
 * Web "Yenilikler" penceresi -- güncellemeden sonraki ilk girişte bir kez
 * açılır, menüden (sidebar altı "Yenilikler") tekrar açılır. Mobil
 * karşılığı mobile/lib/core/whats_new/ (aynı kurallar: kısa başlık, tek
 * cümle, "sen" dili; kişinin göremediği ekranın yeniliği gösterilmez).
 *
 * Neden kodun içinde: notlar anlattıkları kodla AYNI dağıtımda gelir --
 * henüz yayında olmayan bir ekranı anlatmak mümkün olmaz.
 *
 * Yeni yayında: listenin BAŞINA benzersiz bir `key` ile kayıt ekle (sıra =
 * yenilik sırası; karşılaştırma anahtarın listedeki yerine göre yapılır).
 */

export type WhatsNewIcon =
  | "subcontracts"
  | "expenses"
  | "catalog"
  | "change-order"
  | "task-notes"
  | "trial"
  | "person";

export interface WhatsNewItem {
  icon: WhatsNewIcon;
  title: string;
  body: string;
  /** Bu izni olmayana gösterilmez (yoksa herkese). Kod, o özelliği ekranda açan izinle AYNI olmalı. */
  permission?: string;
  /**
   * Yalnızca denemedeki firmanın Sahip/Yöneticisine -- izin koduyla
   * anlatılamayan kural (deneme uyarısını yalnızca onlar görür; deneme
   * bitmiş/hiç olmamış firmada anlamsız).
   */
  trialOwnerAdminOnly?: boolean;
}

export interface WhatsNewRelease {
  /** Bu yayının kalıcı anahtarı -- "görüldü" kaydı bununla tutulur. */
  key: string;
  /** Pencerede görünen ad. */
  label: string;
  items: WhatsNewItem[];
}

/** Bir açılışta gösterilen en fazla madde: birkaç yayını atlayan kişiye uzun bir liste değil, en yeni birkaç şey. */
export const WHATS_NEW_MAX_ITEMS = 7;

/** En yeni yayın en üstte. */
export const WHATS_NEW_RELEASES: WhatsNewRelease[] = [
  // Web'in mobilin gerisinde kaldığı özellikler (docs/web-yapilacaklar.md).
  {
    key: "web-2026-10-1",
    label: "Ekim 2026",
    items: [
      {
        icon: "subcontracts",
        title: "Taşeron sözleşmeleri",
        body: "Projede taşeron sözleşmesi, hakediş ve ödemelerini web'den de yönetebilirsin.",
        // Proje sayfasındaki Taşeron ekranı bu izinle açılır.
        permission: "projects.subcontracts.read",
      },
      {
        icon: "expenses",
        title: "Masrafta KDV ve Masraflarım",
        body: "Masraf girerken KDV oranını seçebilir, girdiğin masrafların onay durumunu Masraflarım'dan izleyebilirsin.",
        // Masraf Ekle ve Masraflarım bu izinle açılır.
        permission: "projects.expenses.create",
      },
      {
        icon: "catalog",
        title: "Teklifte katalog araması",
        body: "Ürün adını yazınca katalogdan öneriler gelir; KDV ve geçerlilik firma ayarlarından dolar.",
        permission: "offers.create",
      },
      {
        icon: "change-order",
        title: "Ek işte müşteri kararı",
        body: "Gönderilen ek işte müşterinin onayını ya da reddini notuyla birlikte işleyebilirsin.",
        permission: "projects.change_orders.approve",
      },
      {
        icon: "task-notes",
        title: "Görev notları",
        body: "Görev detayında not bırakıp ekibi işin durumundan haberdar edebilirsin.",
        permission: "projects.tasks.read",
      },
      {
        icon: "trial",
        title: "Deneme süresi uyarısı",
        body: "Deneme süren bitmeye yaklaşınca üstte bir uyarı çıkar; bugün için kapatabilirsin.",
        trialOwnerAdminOnly: true,
      },
      {
        icon: "person",
        title: "Kişi tek kayıt",
        body: "Yeni kullanıcı açınca personel kaydı da açılır ya da aynı adlı personele bağlanır.",
        // Kullanıcı açabilen görür (Kullanıcılar > Yeni Kullanıcı).
        permission: "organization.users.manage",
      },
    ],
  },
];

export interface WhatsNewViewer {
  /** İzin kontrolü (lib/permissions.ts canAccess ile). */
  can: (permission: string) => boolean;
  /** Firma denemede ve kişi Sahip/Yönetici (organization_role_code owner/admin). */
  trialOwnerAdmin: boolean;
}

export interface WhatsNewNotes {
  /** En yeni yayının anahtarı -- pencere kapanınca "görüldü" olarak yazılır. */
  key: string;
  label: string;
  items: WhatsNewItem[];
}

function visible(item: WhatsNewItem, viewer: WhatsNewViewer): boolean {
  if (item.trialOwnerAdminOnly && !viewer.trialOwnerAdmin) return false;
  return !item.permission || viewer.can(item.permission);
}

function notesOf(newestFirst: WhatsNewRelease[], viewer: WhatsNewViewer): WhatsNewNotes | null {
  if (newestFirst.length === 0) return null;
  const items = newestFirst.flatMap((r) => r.items.filter((item) => visible(item, viewer)));
  if (items.length === 0) return null;
  return { key: newestFirst[0].key, label: newestFirst[0].label, items: items.slice(0, WHATS_NEW_MAX_ITEMS) };
}

/** Görülmemiş yayın var mı: en yeni yayının anahtarı kayıtlı olandan farklıysa. */
export function hasUnseenRelease(lastSeenKey: string | null, releases: WhatsNewRelease[] = WHATS_NEW_RELEASES): boolean {
  return releases.length > 0 && releases[0].key !== lastSeenKey;
}

/**
 * Açılışta gösterilecek notlar: [lastSeenKey]'den yeni bütün yayınların
 * maddeleri birleşir (en yeni önce). Kayıt yoksa ya da kayıtlı anahtar
 * listede yoksa yalnızca en yeni yayın. Zaten görüldüyse ya da izne
 * takılmayan madde kalmadıysa null (anahtar yine "görüldü" yazılmalı ki
 * aynı karar her girişte tekrar verilmesin).
 */
export function whatsNewSince(
  lastSeenKey: string | null,
  viewer: WhatsNewViewer,
  releases: WhatsNewRelease[] = WHATS_NEW_RELEASES
): WhatsNewNotes | null {
  if (!hasUnseenRelease(lastSeenKey, releases)) return null;
  const seenAt = lastSeenKey === null ? -1 : releases.findIndex((r) => r.key === lastSeenKey);
  const newer = seenAt > 0 ? releases.slice(0, seenAt) : releases.slice(0, 1);
  return notesOf(newer, viewer);
}

/**
 * Menüdeki "Yenilikler": kişinin görebileceği maddesi olan en yeni yayın
 * (olmayan yayın atlanır, bir öncekine bakılır); hiçbiri yoksa null.
 */
export function latestWhatsNew(viewer: WhatsNewViewer, releases: WhatsNewRelease[] = WHATS_NEW_RELEASES): WhatsNewNotes | null {
  for (const r of releases) {
    const notes = notesOf([r], viewer);
    if (notes) return notes;
  }
  return null;
}

/** "Görüldü" kaydının localStorage anahtarı -- kişi başına (ortak ofis bilgisayarında herkes bir kez görür). */
export function whatsNewSeenKey(userId: string): string {
  return `arvend.whats_new.web.last_seen.${userId}`;
}
