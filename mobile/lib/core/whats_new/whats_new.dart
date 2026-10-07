import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/domain/user.dart';
import '../auth/permissions.dart';
import '../update/update_controller.dart' show installedVersionProvider;
import 'whats_new_content.dart';

/// Bir açılışta gösterilen en fazla madde: birkaç sürüm atlayan kullanıcıya
/// uzun bir liste değil, en yeni birkaç şey.
const kWhatsNewMaxItems = 6;

/// Yenilikler sayfası gelmeden önceki son build (1.5.8). Kaydı olmayan ama
/// eski bir sürümün üstüne kurulmuş uygulama buradan başlar: bundan yeni her
/// sürümün notu gösterilir.
const kWhatsNewLegacyBuild = 14;

/// Gösterilecek notlar: en yeni sürümün adı + maddeler (en yeni sürüm önce).
@immutable
class WhatsNewNotes {
  const WhatsNewNotes({required this.version, required this.items});

  final String version;
  final List<WhatsNewItem> items;
}

/// [lastSeenBuild]'den yeni, [installedBuild]'e kadar (dahil) bütün
/// sürümlerin maddeleri birleşir. İzni olmayan madde düşer; hiç madde
/// kalmazsa null.
///
/// Kurulu build'den yeni kayıt (sürüm yükseltilmeden önce eklenmiş not)
/// gösterilmez: henüz telefonda olmayan bir şeyi anlatırdı.
WhatsNewNotes? whatsNewSince({
  required int lastSeenBuild,
  required int installedBuild,
  required bool Function(String permission) can,
  List<WhatsNewRelease> releases = kWhatsNewReleases,
}) {
  final newer = [
    for (final r in releases)
      if (r.build > lastSeenBuild && r.build <= installedBuild) r,
  ]..sort((a, b) => b.build.compareTo(a.build));
  return _notesOf(newer, can);
}

/// "Yenilikler" satırı: kurulu sürüme kadarki en yeni notlar. Kullanıcının
/// görebileceği maddesi olmayan sürüm atlanır (bir öncekine bakılır).
/// [installedBuild] bilinmiyorsa üst sınır yoktur.
WhatsNewNotes? latestWhatsNew({
  required int? installedBuild,
  required bool Function(String permission) can,
  List<WhatsNewRelease> releases = kWhatsNewReleases,
}) {
  final candidates = [
    for (final r in releases)
      if (installedBuild == null || r.build <= installedBuild) r,
  ]..sort((a, b) => b.build.compareTo(a.build));
  for (final r in candidates) {
    final notes = _notesOf([r], can);
    if (notes != null) return notes;
  }
  return null;
}

WhatsNewNotes? _notesOf(List<WhatsNewRelease> newestFirst, bool Function(String) can) {
  final items = [
    for (final r in newestFirst)
      for (final item in r.items)
        if (item.permission == null || can(item.permission!)) item,
  ];
  if (items.isEmpty) return null;
  return WhatsNewNotes(version: newestFirst.first.version, items: items.take(kWhatsNewMaxItems).toList());
}

/// Uygulama eski bir kurulumun ÜSTÜNE mi geldi -- Android'in kendi kaydı:
/// paket yerinde güncellendiyse `lastUpdateTime` ilk kurulum zamanından
/// sonradır, sıfırdan kurulumda ikisi aynıdır.
bool isUpdatedInPlace({required DateTime? installTime, required DateTime? updateTime}) =>
    installTime != null && updateTime != null && updateTime.isAfter(installTime);

/// Kayıt yokken "eski kullanıcı güncelledi mi" sorusunun cevabı.
///
/// Neden kendi kayıtlarımız değil: bugün güncelleyen herkes 1.5.7/1.5.8'den
/// geliyor ve 1.5.7 güvenilir bir iz BIRAKMIYOR -- son kullanıcı kaydı
/// (LastUserStore) 1.5.8'de geldi; ana sayfa "Gizle" ve güncelleme
/// erteleme kayıtları yalnızca o düğmelere basanlarda var; oturum çerezi
/// çıkışta siliniyor. Üstelik giriş yapınca uygulama son kullanıcıyı HEMEN
/// yazıyor, kabuk açıldığında "eski kullanıcı" ile "az önce giriş yaptı"
/// ayırt edilemiyor. Android'in kaydı ise tam olarak "eski sürümün üstüne
/// kuruldu" demek ve bizim hangi sürümde ne yazdığımıza bağlı değil.
///
/// Sınırlar: Play'den kurulup ilk açılıştan ÖNCE bir kez daha güncellenen
/// telefon güncelleme sayılır (yeni kullanıcı notları bir kez görür --
/// zararsız). Kaldırıp yeniden kurmak (sideload'dan Play'e geçiş) sıfırdan
/// kurulumdur; o telefonda zaten hiçbir eski kayıt kalmaz. iOS'ta bu
/// zamanlar güvenilir değil (paket klasörünün tarihi) ve Yenilikler'den önce
/// yayınlanmış bir iOS sürümü yok -- her iOS kurulumu sıfırdandır.
final appUpdatedInPlaceProvider = FutureProvider<bool>((ref) async {
  if (kIsWeb || !Platform.isAndroid) return false;
  final info = await PackageInfo.fromPlatform();
  return isUpdatedInPlace(installTime: info.installTime, updateTime: info.updateTime);
});

/// Bu telefonda Yenilikler'in en son gösterildiği (ya da sessizce geçildiği)
/// build (SharedPreferences). Hatalar çağırana fırlar -- WhatsNewController
/// hepsini yutar.
class WhatsNewStore {
  WhatsNewStore({Future<SharedPreferences> Function()? prefs}) : _prefs = prefs ?? SharedPreferences.getInstance;

  static const lastSeenBuildKey = 'arvend.whats_new.last_seen_build';

  final Future<SharedPreferences> Function() _prefs;

  Future<int?> lastSeenBuild() async => (await _prefs()).getInt(lastSeenBuildKey);

  Future<void> setLastSeenBuild(int build) async {
    await (await _prefs()).setInt(lastSeenBuildKey, build);
  }
}

final whatsNewStoreProvider = Provider<WhatsNewStore>((ref) => WhatsNewStore());

/// Uygulamadaki notlar (testler sürüm atlama/izin senaryoları için değiştirir).
final whatsNewReleasesProvider = Provider<List<WhatsNewRelease>>((ref) => kWhatsNewReleases);

/// Açılışta gösterilecek olan: kurulu build ve (varsa) notlar. [notes] null
/// ise gösterilecek madde yok (ör. hepsi izne takıldı) ama build yine
/// kaydedilir -- bir sonraki açılışta aynı karar tekrar verilmesin.
@immutable
class WhatsNewPending {
  const WhatsNewPending({required this.build, this.notes});

  final int build;
  final WhatsNewNotes? notes;
}

/// Yenilikler'in tek sahibi. Hiçbir yöntemi hata FIRLATMAZ: bir sürüm notu
/// gösterilemedi diye uygulama bozulmamalı -- en kötü ihtimalle bir sonraki
/// açılışta yeniden denenir.
class WhatsNewController {
  WhatsNewController(this._ref);

  final Ref _ref;
  Future<void>? _prepared;

  WhatsNewStore get _store => _ref.read(whatsNewStoreProvider);

  /// Kaydın tabanı: kayıt yoksa (Yenilikler'den önceki bir sürümden gelindi
  /// ya da ilk kurulum) bir kez yazılır. Güncellemede [kWhatsNewLegacyBuild]
  /// (bundan yeni notlar gösterilir), sıfırdan kurulumda kurulu build
  /// (yeni kullanıcıya "yenilik" yok). main.dart açılışta, giriş beklemeden
  /// çağırır: hiç giriş yapılmadan bir sonraki sürüme güncellenen yeni
  /// kurulum, o zaman "eski kullanıcı" sanılmasın.
  Future<void> prepare() => _prepared ??= _prepare();

  Future<void> _prepare() async {
    try {
      if (await _store.lastSeenBuild() != null) return;
      final installed = await _ref.read(installedVersionProvider.future);
      if (installed.build <= 0) return;
      final upgraded = await _ref.read(appUpdatedInPlaceProvider.future);
      await _store.setLastSeenBuild(upgraded ? kWhatsNewLegacyBuild : installed.build);
    } catch (e) {
      debugPrint('Yenilikler kaydı hazırlanamadı: $e');
    }
  }

  /// Bu açılışta yapılacak iş; yoksa (zaten görüldü, kayıt okunamadı) null.
  Future<WhatsNewPending?> pending(User user) async {
    try {
      await prepare();
      final lastSeen = await _store.lastSeenBuild();
      // Taban yazılamadıysa güncelleme mi ilk kurulum mu bilinmiyor --
      // yanlış kişiye göstermektense bu açılış geçilir.
      if (lastSeen == null) return null;
      final installed = await _ref.read(installedVersionProvider.future);
      if (installed.build <= lastSeen) return null;
      return WhatsNewPending(
        build: installed.build,
        notes: whatsNewSince(
          lastSeenBuild: lastSeen,
          installedBuild: installed.build,
          can: user.can,
          releases: _ref.read(whatsNewReleasesProvider),
        ),
      );
    } catch (e) {
      debugPrint('Yenilikler denetlenemedi: $e');
      return null;
    }
  }

  Future<void> markSeen(int build) async {
    try {
      await _store.setLastSeenBuild(build);
    } catch (e) {
      // Yazılamazsa en kötü ihtimalle bir sonraki açılışta yine gösterilir.
      debugPrint('Yenilikler kaydı yazılamadı: $e');
    }
  }

  /// "Yenilikler" satırı için en yeni notlar.
  Future<WhatsNewNotes?> latest(User? user) async {
    int? installed;
    try {
      final build = (await _ref.read(installedVersionProvider.future)).build;
      if (build > 0) installed = build;
    } catch (_) {
      // Sürüm okunamazsa listedeki en yeni kayıt gösterilir.
    }
    return latestWhatsNew(installedBuild: installed, can: user.can, releases: _ref.read(whatsNewReleasesProvider));
  }
}

final whatsNewControllerProvider = Provider<WhatsNewController>(WhatsNewController.new);
