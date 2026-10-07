import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_providers.dart';
import '../config/app_config.dart';
import 'apk_installer.dart';
import 'app_release.dart';
import 'update_postpone_store.dart';
import 'update_repository.dart';
import 'update_service.dart';

/// Uzaktan güncelleme yalnızca sideload Android sürümünde çalışır -- store'a
/// çıkana kadar APK sunucudan dağıtılıyor. iOS/web'de ve Google Play
/// sürümünde modülün TAMAMI no-op'tur: Play, Play dışı güncellemeyi
/// yasaklıyor; Play sürümünde onun yerine Play'in uygulama içi güncellemesi
/// çalışır (bkz. play_update.dart, AppConfig.isPlayBuild). Testler bunu override eder
/// (flutter test macOS/Linux üstünde koşar, `Platform.isAndroid` false'tur --
/// bu yüzden mevcut testlerin hiçbiri ek bir istek görmez).
final updateSupportedProvider =
    Provider<bool>((ref) => !kIsWeb && Platform.isAndroid && !AppConfig.isPlayBuild);

/// Test edilebilir saat (erteleme süresi / 6 saatlik yeniden denetim).
final updateClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Kurulu sürüm -- build numarası `PackageInfo.buildNumber` (Android
/// versionCode). Sabit kodlanmış bir sürüm YOK.
final installedVersionProvider = FutureProvider<InstalledVersion>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return InstalledVersion(version: info.version, build: int.tryParse(info.buildNumber) ?? 0);
});

final updateRepositoryProvider = Provider<UpdateRepository>(
  (ref) => UpdateRepository(ref.watch(apiClientProvider)),
);

final updatePostponeStoreProvider = Provider<UpdatePostponeStore>(
  (ref) => UpdatePostponeStore(clock: ref.watch(updateClockProvider)),
);

final updateInstallServiceProvider = Provider<UpdateInstallService>(
  (ref) => UpdateInstallService(
    downloader: ApiUpdateDownloader(ref.watch(apiClientProvider)),
    installer: const PlatformApkInstaller(),
    baseDirectory: getApplicationCacheDirectory,
  ),
);

/// Denetimi ne başlattı -- erteleme ve temizlik kararları buna göre.
enum UpdateCheckTrigger { startup, resume, login, manual }

enum UpdateCheckStatus {
  /// Android değil -- hiçbir şey yapılmadı.
  unsupported,

  /// Ağ/sunucu hatası. Otomatik denetimlerde SESSİZ geçilir.
  failed,

  /// Kurulu sürüm güncel (ya da sunucuda geçerli bir sürüm yok).
  upToDate,

  /// Daha yeni bir sürüm var.
  available,
}

class UpdateCheckResult {
  const UpdateCheckResult(
    this.status, {
    this.release,
    this.installed,
    this.mandatory = false,
    this.postponed = false,
  });

  final UpdateCheckStatus status;
  final AppRelease? release;
  final InstalledVersion? installed;

  /// Kurulu build `min_build`'in altında -- "Sonra" yok, kapatılamaz.
  final bool mandatory;

  /// Otomatik denetimde kullanıcı bu build'i son 24 saatte ertelemiş --
  /// sorulmaz. Elle denetimde ve zorunlu güncellemede her zaman false.
  final bool postponed;

  /// Kullanıcıya şimdi sorulmalı mı.
  bool get shouldPrompt => status == UpdateCheckStatus.available && !postponed;
}

@immutable
class UpdateState {
  const UpdateState({this.release, this.installed, this.lastCheckedAt, this.awaitingLogin = false});

  /// Son BAŞARILI denetimde sunucudan gelen sürüm.
  final AppRelease? release;
  final InstalledVersion? installed;

  /// Son BAŞARILI denetim -- başarısız denetim bunu güncellemez, böylece
  /// uygulama bir sonraki öne gelişinde tekrar denenir.
  final DateTime? lastCheckedAt;

  /// Kullanıcı "Güncelle" dedi ama oturum yoktu (ya da indirme 401 aldı) --
  /// giriş yapılınca istem tekrar gösterilir.
  final bool awaitingLogin;

  bool get hasMandatoryUpdate {
    final r = release;
    final i = installed;
    return r != null && i != null && r.isMandatoryFor(i.build);
  }

  UpdateState copyWith({
    AppRelease? release,
    InstalledVersion? installed,
    DateTime? lastCheckedAt,
    bool? awaitingLogin,
  }) =>
      UpdateState(
        release: release ?? this.release,
        installed: installed ?? this.installed,
        lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
        awaitingLogin: awaitingLogin ?? this.awaitingLogin,
      );
}

/// Güncelleme denetiminin tek sahibi. Ekranlar/diyaloglar buradaki
/// sonuca göre davranır (bkz. update_presenter.dart); denetim kendisi
/// hiçbir zaman hata fırlatmaz.
class UpdateController extends Notifier<UpdateState> {
  /// Uygulama öne geldiğinde son başarılı denetim bundan eskiyse tekrar
  /// sorulur.
  static const resumeInterval = Duration(hours: 6);

  Future<UpdateCheckResult>? _inFlight;
  bool _presenting = false;

  @override
  UpdateState build() => const UpdateState();

  bool get _supported => ref.read(updateSupportedProvider);

  /// Sunucuya sorar. Aynı anda gelen denetimler TEK isteği paylaşır.
  Future<UpdateCheckResult> check({required UpdateCheckTrigger trigger}) {
    if (!_supported) return Future.value(const UpdateCheckResult(UpdateCheckStatus.unsupported));
    final running = _inFlight;
    if (running != null) {
      // Elle denetim, çalışan otomatik denetimin ERTELEME kararını
      // miras almamalı -- sonucu kendi kuralıyla yeniden yorumlanır.
      return trigger == UpdateCheckTrigger.manual ? running.then(_asManual) : running;
    }
    final future = _check(trigger).whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  /// Süren bir denetim varsa bitmesini bekler. Yenilikler sayfası açılış
  /// denetiminin kararını (zorunlu güncelleme var mı) bununla bekler; yeni
  /// istek atmaz. Denetim hata fırlatmadığı için bu da fırlatmaz.
  Future<void> whenIdle() async {
    final running = _inFlight;
    if (running != null) await running;
  }

  UpdateCheckResult _asManual(UpdateCheckResult r) => r.postponed
      ? UpdateCheckResult(r.status, release: r.release, installed: r.installed, mandatory: r.mandatory)
      : r;

  Future<UpdateCheckResult> _check(UpdateCheckTrigger trigger) async {
    try {
      final installed = await ref.read(installedVersionProvider.future);
      final release = await ref.read(updateRepositoryProvider).fetchLatest();
      final now = ref.read(updateClockProvider)();
      state = state.copyWith(release: release, installed: installed, lastCheckedAt: now);

      final newer = release.isNewerThan(installed.build);
      if (trigger == UpdateCheckTrigger.startup) {
        // Başarılı bir güncellemeden sonra eski APK cache'te kalmasın.
        unawaited(ref.read(updateInstallServiceProvider).cleanup(keepBuild: newer ? release.build : null));
      }
      if (!newer) {
        return UpdateCheckResult(UpdateCheckStatus.upToDate, release: release, installed: installed);
      }
      final mandatory = release.isMandatoryFor(installed.build);
      final postponed = trigger != UpdateCheckTrigger.manual &&
          !mandatory &&
          await ref.read(updatePostponeStoreProvider).isPostponed(release.build);
      return UpdateCheckResult(
        UpdateCheckStatus.available,
        release: release,
        installed: installed,
        mandatory: mandatory,
        postponed: postponed,
      );
    } catch (e) {
      // Güncelleme denetimi uygulamayı ASLA bozmaz; kullanıcıya hata
      // diyaloğu gösterilmez (elle denetimde ekran kendi mesajını verir).
      debugPrint('Güncelleme denetimi başarısız: $e');
      return const UpdateCheckResult(UpdateCheckStatus.failed);
    }
  }

  /// Uygulama öne geldiğinde yeniden sorulmalı mı (son başarılı denetim 6
  /// saatten eski ya da hiç yapılmadı).
  bool get isStale {
    final last = state.lastCheckedAt;
    if (last == null) return true;
    return ref.read(updateClockProvider)().difference(last) >= resumeInterval;
  }

  /// Son bilinen sonuç (yeniden istek atmadan) -- giriş sonrası ve zorunlu
  /// güncellemede istemi tekrar göstermek için.
  UpdateCheckResult? get cachedAvailable {
    final r = state.release;
    final i = state.installed;
    if (r == null || i == null || !r.isNewerThan(i.build)) return null;
    return UpdateCheckResult(
      UpdateCheckStatus.available,
      release: r,
      installed: i,
      mandatory: r.isMandatoryFor(i.build),
    );
  }

  /// "Sonra": BU build 24 saat boyunca otomatik olarak sorulmaz.
  Future<void> postpone(AppRelease release) => ref.read(updatePostponeStoreProvider).postpone(release.build);

  void setAwaitingLogin(bool value) {
    if (state.awaitingLogin != value) state = state.copyWith(awaitingLogin: value);
  }

  /// Aynı anda tek bir güncelleme istemi/akışı -- otomatik denetim ile
  /// "Güncellemeleri denetle" üst üste iki diyalog açmasın.
  bool get isPresenting => _presenting;

  bool tryBeginPresentation() {
    if (_presenting) return false;
    _presenting = true;
    return true;
  }

  void endPresentation() => _presenting = false;
}

final updateControllerProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
