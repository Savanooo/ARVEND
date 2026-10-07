import 'package:flutter/material.dart';

/// "Yenilikler" sayfasının içeriği -- güncellemeden sonraki ilk açılışta bir
/// kez gösterilir (bkz. whats_new.dart).
///
/// Neden uygulamanın İÇİNDE, sunucudan değil: Play sürümü sürüm bilgisini
/// bizim sunucumuza sormaz (sunucudaki `latest.json` notları yalnızca
/// sideload içindir), şantiyedeki telefon çoğu zaman çekmez ve notlar
/// anlattıkları kodla AYNI pakette gelir -- yeni bir ekranı, o ekran henüz
/// telefonda yokken anlatmak mümkün olmaz.
///
/// Yeni sürümde: pubspec.yaml'daki `+N` ile listenin BAŞINA bir kayıt ekle.
/// Kaydı olmayan sürümde sayfa hiç açılmaz; `scripts/derle.sh` bu yüzden
/// uyarır (RELEASE.md §14).
///
/// Maddeler: başlık 2-4 kelime, açıklama tek kısa cümle, "sen" diliyle.
/// Okuyan şantiye ekibi ve ofis; teknik terim değil, ekranda göreceği şey.
@immutable
class WhatsNewItem {
  const WhatsNewItem({required this.icon, required this.title, required this.body, this.permission});

  final IconData icon;
  final String title;
  final String body;

  /// Bu izni olmayana gösterilmez (null = herkese). Göremediği bir ekranın
  /// yeniliğini okumak kafa karıştırır: "Masrafa KDV" yalnızca masraf
  /// girebilene anlamlı. Kod, o özelliği ekranda açan izinle AYNI olmalı.
  final String? permission;
}

@immutable
class WhatsNewRelease {
  const WhatsNewRelease({required this.build, required this.version, required this.items});

  /// pubspec.yaml'daki `+N` (Android versionCode) -- karşılaştırma bununla
  /// yapılır, sürüm adına bakılmaz.
  final int build;

  /// Ekranda "Sürüm …" olarak görünen ad.
  final String version;
  final List<WhatsNewItem> items;
}

/// En yeni sürüm en üstte.
const kWhatsNewReleases = <WhatsNewRelease>[
  // Masrafı herkes girer, onayı en üst yönetim verir (backend migration
  // 0066). pubspec henüz 1.5.9+15: sürümü ürün sahibi yükseltir.
  WhatsNewRelease(
    build: 16,
    version: '1.5.10',
    items: [
      WhatsNewItem(
        icon: Icons.receipt_long_outlined,
        title: 'Herkes masraf girebilir',
        body: 'Masrafını gir, onay durumunu Masraflarım\'dan takip et.',
        // Hızlı işlem, proje ekranı ve Masraflarım bu izinle açılır.
        permission: 'projects.expenses.create',
      ),
      WhatsNewItem(
        icon: Icons.verified_user_outlined,
        title: 'Masraf onayı yönetimde',
        body: 'Masrafları yalnızca Sahip ve Yönetici onaylar; kimse kendi masrafını onaylamaz.',
        permission: 'projects.expenses.approve',
      ),
    ],
  ),
  // 1.5.8 kullanıcıya not göstermeden çıktı; bu kayıt 1.5.7'den beri
  // gelenleri anlatır.
  WhatsNewRelease(
    build: 15,
    version: '1.5.9',
    items: [
      WhatsNewItem(
        icon: Icons.fact_check_outlined,
        title: 'Masraf onayı',
        body: 'Masraflar onaya düşer; onaylanınca toplamlara girer.',
        // Masraf listesi ve özet bu izinle görünür (proje Finans grubu).
        permission: 'projects.finance.read',
      ),
      WhatsNewItem(
        icon: Icons.percent,
        title: 'Masrafa KDV',
        body: 'Masraf girerken KDV oranını seçebilir, sonradan düzenleyebilirsin.',
        permission: 'projects.finance.manage',
      ),
      WhatsNewItem(
        icon: Icons.insights_outlined,
        title: 'KDV hariç kâr',
        body: 'Finans özetinde kâr KDV hariç ve KDV dahil ayrı görünür.',
        // Finansal Özet kartının izni (project_detail_screen.dart).
        permission: 'projects.finance.read',
      ),
      WhatsNewItem(
        icon: Icons.picture_as_pdf_outlined,
        title: 'Teklif PDF',
        body: 'Teklifi PDF olarak indirip müşteriye gönderebilirsin.',
        permission: 'offers.read',
      ),
      WhatsNewItem(
        icon: Icons.swipe_down_outlined,
        title: 'Kolay kapanan formlar',
        body: 'Formları aşağı çekerek kapatabilirsin.',
      ),
      WhatsNewItem(
        icon: Icons.pin_outlined,
        title: 'Doğru tutar girişi',
        body: '1.250,50 gibi tutarlar artık doğru okunuyor.',
      ),
    ],
  ),
];
