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
  // Proje silme (backend 0070); Ana Sayfa "Masraf Gir" genel masrafı da
  // sorar. Build 23 yalnızca TestFlight'a gitti, mağazaya 24 çıkar.
  WhatsNewRelease(
    build: 24,
    version: '1.5.17',
    items: [
      WhatsNewItem(
        icon: Icons.delete_outline,
        title: 'Proje silme',
        body: 'Yanlış açılan projeyi sağ üstteki menüden silebilir ya da yöneticine silme talebi gönderebilirsin.',
        permission: 'projects.update',
      ),
      WhatsNewItem(
        icon: Icons.receipt_long_outlined,
        title: 'Ana Sayfa\'dan genel masraf',
        body: 'Ana Sayfa\'daki "Masraf Gir" artık proje seçtirmeden genel masraf da girer.',
        permission: 'projects.expenses.create',
      ),
    ],
  ),
  // Ürün sahibinin istekleri (2026-10-14): teklif silme onayı, projesiz
  // masraf ve tek Masraflar listesi, Taşeronlar.
  WhatsNewRelease(
    build: 22,
    version: '1.5.16',
    items: [
      WhatsNewItem(
        icon: Icons.engineering_outlined,
        title: 'Taşeronlar sayfası',
        body: 'Taşeronu bir kez gir, projelerde listeden seç; proje içi ve proje dışı bütün ödemeleri tek sayfada gör.',
        permission: 'organization.suppliers.read',
      ),
      WhatsNewItem(
        icon: Icons.receipt_long_outlined,
        title: 'Projesiz masraf',
        body: 'Ofis, yakıt gibi genel giderleri proje seçmeden gir; bütün masrafların Diğer > Masraflar\'da.',
        permission: 'projects.expenses.create',
      ),
      WhatsNewItem(
        icon: Icons.delete_outline,
        title: 'Teklif silme onayı',
        body: 'Silme yetkin yoksa teklifi silme talebiyle yöneticine onaya gönderirsin.',
        permission: 'offers.update',
      ),
    ],
  ),
  // App Store incelemesi (5.1.1(v)): hesap uygulamanın içinden silinebilmeli.
  WhatsNewRelease(
    build: 21,
    version: '1.5.15',
    items: [
      WhatsNewItem(
        icon: Icons.person_remove_outlined,
        title: 'Hesap silme',
        body: 'Profil > Hesabımı Sil ile hesabını şifrenle onaylayıp kalıcı olarak silebilirsin.',
      ),
    ],
  ),
  // Mobil düzeltme sürümü: paylaşım menüsü, teklif geçerlilik tarihi,
  // metraj ve müşteri kartı düzeltmeleri, anlık yetki tazeleme.
  WhatsNewRelease(
    build: 20,
    version: '1.5.14',
    items: [
      WhatsNewItem(
        icon: Icons.share_outlined,
        title: 'WhatsApp ile paylaş',
        body: 'Teklif PDF\'ini, linki, proje dosyalarını ve fotoğrafları tek dokunuşla gönderebilirsin.',
      ),
      WhatsNewItem(
        icon: Icons.event_outlined,
        title: 'Teklifte geçerlilik tarihi',
        body: 'Teklif formunda tarihi seçebilir ya da süresiz yapabilirsin; süresi geçmiş taslaklar artık kaydediliyor.',
        // Teklif formu bu izinle açılır.
        permission: 'offers.create',
      ),
      WhatsNewItem(
        icon: Icons.calculate_outlined,
        title: 'Metraj doğru hesaplar',
        body: 'Çatı eğimi başka hesaplara taşınmıyor; metrajdaki tutar teklife aynen geçiyor.',
        // Metraj ekranı teklif formundan açılır.
        permission: 'offers.create',
      ),
      WhatsNewItem(
        icon: Icons.person_outline,
        title: 'Müşteri kartı güncel',
        body: 'Yeni teklif ve tahsilat karta hemen yansıyor; iptal edilen projeler alacağa sayılmıyor.',
        permission: 'customers.read',
      ),
      WhatsNewItem(
        icon: Icons.verified_user_outlined,
        title: 'Yetkiler hemen geçerli',
        body: 'Yöneticinin verdiği ya da kaldırdığı yetkiler uygulamayı kapatıp açmadan görünür.',
      ),
    ],
  ),
  // Taslak teklifin linki müşteriye Kabul Et / Reddet göstermiyordu
  // (backend: share-links mark_sent).
  WhatsNewRelease(
    build: 18,
    version: '1.5.12',
    items: [
      WhatsNewItem(
        icon: Icons.send_outlined,
        title: 'Linkle onay',
        body: 'Taslak teklifi linkle paylaşırken Gönderildi yapılır; müşteri linkten onaylayabilir.',
        // "Gönder ve link oluştur" bu izinle açılır (teklif durumunu
        // değiştirme); izni olmayan yalnızca önizleme linki oluşturur.
        permission: 'offers.approve',
      ),
    ],
  ),
  // Teklif kaleminde katalog önerileri (backend: kelime bazlı ürün araması).
  WhatsNewRelease(
    build: 17,
    version: '1.5.11',
    items: [
      WhatsNewItem(
        icon: Icons.inventory_2_outlined,
        title: 'Katalogdan ürün seç',
        body: 'Teklifte ürün adını yazınca katalogdan öneriler gelir; seçince birim ve fiyat dolar.',
        // Teklif formu bu izinle açılır; öneriler ayrıca products.read ister
        // (offers.create taşıyan varsayılan rollerin hepsinde var).
        permission: 'offers.create',
      ),
      WhatsNewItem(
        icon: Icons.badge_outlined,
        title: 'Kişi tek kayıt',
        body: 'Yeni kullanıcı açınca personel kaydı da açılır; görev atayınca bildirim doğrudan telefonuna gider.',
        // Kullanıcı açabilen görür (Kişiler > Yeni Kullanıcı).
        permission: 'organization.users.manage',
      ),
    ],
  ),
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
        body: 'Masrafları Sahip ve Yönetici onaylar; Yönetici kendi masrafını onaylayamaz.',
        permission: 'projects.expenses.approve',
      ),
      WhatsNewItem(
        icon: Icons.notifications_active_outlined,
        title: 'Teklif bildirimleri',
        body: 'Müşteri teklifi açınca, onaylayınca ya da reddedince bildirim gelir.',
        // Teklif kararı/ilk açılış bildirimleri teklifleri görebilene gider.
        permission: 'offers.read',
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
