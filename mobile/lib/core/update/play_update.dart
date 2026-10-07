import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_update/in_app_update.dart' as iau;

import '../config/app_config.dart';
import '../push/push_watcher.dart' show rootScaffoldMessengerKey;
import 'update_controller.dart';

/// Google Play sürümünde güncelleme: Play'in kendi uygulama içi güncelleme
/// API'si (In-App Updates). Sideload yapısındaki kendi güncelleyicimizin
/// (update_controller.dart) Play'deki karşılığı -- Play, uygulamanın kendini
/// Play dışından güncellemesini yasaklıyor ama bu API'ye izin veriyor.
///
/// - Normal yeni sürüm: Play'in kendi onay penceresi açılır, indirme arka
///   planda sürer; inince "Yeniden başlat" çubuğu çıkar.
/// - Zorunlu: kurulu build sunucudaki `min_build`'in altındaysa (sideload ile
///   AYNI ayar, aynı versionCode dizisi) tam ekran güncelleme açılır ve
///   kullanıcı vazgeçse de uygulama her öne gelişinde yeniden açılır.
///
/// Sideload yapısında ve iOS/web'de modülün tamamı no-op'tur.
final playUpdateSupportedProvider =
    Provider<bool>((ref) => !kIsWeb && Platform.isAndroid && AppConfig.isPlayBuild);

/// Play'den gelen durumun bize gereken kısmı.
@immutable
class PlayUpdateInfo {
  const PlayUpdateInfo({
    this.available = false,
    this.inProgress = false,
    this.downloading = false,
    this.downloaded = false,
    this.immediateAllowed = false,
    this.flexibleAllowed = false,
    this.versionCode,
  });

  /// Play'de kurulu olandan yeni bir sürüm var.
  final bool available;

  /// Uygulamanın başlattığı bir güncelleme yarım kaldı (tam ekran güncellemeden
  /// çıkılıp geri dönüldü ya da arka planda indirme sürüyor).
  final bool inProgress;

  /// Arka planda indirme sürüyor.
  final bool downloading;

  /// Arka planda indirme bitti, kurulum bekliyor.
  final bool downloaded;

  final bool immediateAllowed;
  final bool flexibleAllowed;

  /// Play'deki sürümün versionCode'u (erteleme bu sürüme bağlanır).
  final int? versionCode;
}

enum PlayUpdateOutcome { completed, denied, failed }

/// Play API'sinin ince sarmalayıcısı -- testler sahtesini koyar.
abstract class PlayUpdateClient {
  Future<PlayUpdateInfo> check();

  /// Play'in onay penceresi; Future indirme BİTİNCE (ya da kullanıcı
  /// vazgeçince) tamamlanır.
  Future<PlayUpdateOutcome> startFlexible();

  /// Tam ekran güncelleme -- Play yönetir, bitince uygulama yeniden açılır.
  Future<PlayUpdateOutcome> performImmediate();

  /// İnen güncellemeyi kurar; uygulama yeniden başlar.
  Future<void> completeFlexible();
}

class PluginPlayUpdateClient implements PlayUpdateClient {
  const PluginPlayUpdateClient();

  @override
  Future<PlayUpdateInfo> check() async {
    final info = await iau.InAppUpdate.checkForUpdate();
    return PlayUpdateInfo(
      available: info.updateAvailability == iau.UpdateAvailability.updateAvailable,
      inProgress: info.updateAvailability == iau.UpdateAvailability.developerTriggeredUpdateInProgress,
      downloading: info.installStatus == iau.InstallStatus.pending || info.installStatus == iau.InstallStatus.downloading,
      downloaded: info.installStatus == iau.InstallStatus.downloaded,
      immediateAllowed: info.immediateUpdateAllowed,
      flexibleAllowed: info.flexibleUpdateAllowed,
      versionCode: info.availableVersionCode,
    );
  }

  @override
  Future<PlayUpdateOutcome> startFlexible() => _run(iau.InAppUpdate.startFlexibleUpdate);

  @override
  Future<PlayUpdateOutcome> performImmediate() => _run(iau.InAppUpdate.performImmediateUpdate);

  @override
  Future<void> completeFlexible() => iau.InAppUpdate.completeFlexibleUpdate();

  static Future<PlayUpdateOutcome> _run(Future<iau.AppUpdateResult> Function() start) async {
    try {
      return switch (await start()) {
        iau.AppUpdateResult.success => PlayUpdateOutcome.completed,
        iau.AppUpdateResult.userDeniedUpdate => PlayUpdateOutcome.denied,
        iau.AppUpdateResult.inAppUpdateFailed => PlayUpdateOutcome.failed,
      };
    } on PlatformException catch (e) {
      debugPrint('Play güncellemesi başarısız: ${e.code} ${e.message}');
      return PlayUpdateOutcome.failed;
    }
  }
}

final playUpdateClientProvider = Provider<PlayUpdateClient>((ref) => const PluginPlayUpdateClient());

enum PlayUpdateStatus {
  /// Play yapısı değil -- hiçbir şey yapılmadı.
  unsupported,

  /// Play'e ulaşılamadı (ör. uygulama Play'den kurulmamış, ağ yok).
  failed,

  upToDate,

  /// Kullanıcı bu sürümü son 24 saatte reddetmiş -- otomatik denetimde sorulmaz.
  postponed,

  /// Arka planda indirme sürüyor.
  downloading,

  /// İndirme bitti -- "Yeniden başlat" gösterilmeli.
  readyToInstall,

  /// Kullanıcı Play'in penceresinde vazgeçti.
  denied,

  /// Tam ekran güncelleme başladı (Play yönetiyor).
  started,
}

/// Play güncellemesinin tek sahibi: açılış/öne gelme (PlayUpdateWatcher) ve
/// "Güncellemeleri denetle" (Hakkında ekranı) aynı akışı kullanır.
class PlayUpdateController {
  PlayUpdateController(this._ref);

  /// Öne gelişte, son denetim bundan eskiyse yeniden sorulur.
  static const resumeInterval = Duration(hours: 6);

  final Ref _ref;
  bool _busy = false;
  DateTime? _lastCheckedAt;
  final _firstDecision = Completer<void>();

  /// Son denetimde güncelleme zorunluydu -- her öne gelişte yeniden denenir.
  bool mandatoryPending = false;

  /// İlk denetimde güncellemenin zorunlu olup olmadığı belli oldu
  /// ([mandatoryPending] artık doğru). Yenilikler sayfası zorunlu
  /// güncellemenin üstüne açılmasın diye bunu bekler. Play'in penceresi
  /// açılmadan ÖNCE tamamlanır: esnek güncellemenin indirmesi dakikalar
  /// sürebilir, onu beklemek gereksiz.
  Future<void> get firstDecision => _firstDecision.future;

  bool get isStale {
    final last = _lastCheckedAt;
    return last == null || _ref.read(updateClockProvider)().difference(last) >= resumeInterval;
  }

  /// Play'e sorar ve gerekiyorsa Play'in penceresini açar. [onChecked] Play
  /// cevap verir vermez (pencere açılmadan ÖNCE) çağrılır -- elle denetimde
  /// satırın dönen göstergesi indirme boyunca kilitli kalmasın. Hata
  /// FIRLATMAZ.
  Future<PlayUpdateStatus> run({required bool manual, VoidCallback? onChecked}) async {
    void checked() {
      if (!_firstDecision.isCompleted) _firstDecision.complete();
      onChecked?.call();
    }

    if (!_ref.read(playUpdateSupportedProvider)) {
      checked();
      return PlayUpdateStatus.unsupported;
    }
    if (_busy) {
      // Play'in penceresi açık ya da indirme sürüyor.
      checked();
      return PlayUpdateStatus.downloading;
    }
    _busy = true;
    try {
      return await _run(manual, checked);
    } finally {
      _busy = false;
      checked();
    }
  }

  Future<PlayUpdateStatus> _run(bool manual, VoidCallback? onChecked) async {
    final client = _ref.read(playUpdateClientProvider);
    final PlayUpdateInfo info;
    try {
      info = await client.check();
    } catch (e) {
      debugPrint('Play güncelleme denetimi başarısız: $e');
      return PlayUpdateStatus.failed;
    }
    _lastCheckedAt = _ref.read(updateClockProvider)();

    if (info.downloaded) {
      onChecked?.call();
      return PlayUpdateStatus.readyToInstall;
    }
    if (info.downloading) {
      onChecked?.call();
      return PlayUpdateStatus.downloading;
    }
    if (!info.available && !info.inProgress) {
      mandatoryPending = false;
      return PlayUpdateStatus.upToDate;
    }

    final mandatory = await _isMandatory();
    mandatoryPending = mandatory;
    onChecked?.call();

    if (mandatory && (info.inProgress || info.immediateAllowed)) return _immediate(client);
    if (info.inProgress) return PlayUpdateStatus.downloading;

    final versionCode = info.versionCode ?? 0;
    final store = _ref.read(updatePostponeStoreProvider);
    if (!manual && !mandatory && await store.isPostponed(versionCode)) return PlayUpdateStatus.postponed;

    if (info.flexibleAllowed) {
      switch (await client.startFlexible()) {
        case PlayUpdateOutcome.completed:
          return PlayUpdateStatus.readyToInstall;
        case PlayUpdateOutcome.denied:
          if (!mandatory) await store.postpone(versionCode);
          return PlayUpdateStatus.denied;
        case PlayUpdateOutcome.failed:
          return PlayUpdateStatus.failed;
      }
    }
    // Play arka planda indirmeye izin vermiyorsa tek yol tam ekran güncelleme.
    if (info.immediateAllowed) return _immediate(client);
    return PlayUpdateStatus.failed;
  }

  Future<PlayUpdateStatus> _immediate(PlayUpdateClient client) async {
    return switch (await client.performImmediate()) {
      PlayUpdateOutcome.completed => PlayUpdateStatus.started,
      PlayUpdateOutcome.denied => PlayUpdateStatus.denied,
      PlayUpdateOutcome.failed => PlayUpdateStatus.failed,
    };
  }

  /// Sideload ile aynı ayar: kurulu build sunucudaki `min_build`'in altında.
  /// Sunucuya ulaşılamazsa zorunlu SAYILMAZ (kullanıcı kilitlenmez).
  Future<bool> _isMandatory() async {
    try {
      final installed = await _ref.read(installedVersionProvider.future);
      final release = await _ref.read(updateRepositoryProvider).fetchLatest();
      return release.minBuild > 0 && installed.build < release.minBuild;
    } catch (e) {
      debugPrint('Zorunlu güncelleme bilgisi alınamadı: $e');
      return false;
    }
  }

  Future<void> completeUpdate() async {
    try {
      await _ref.read(playUpdateClientProvider).completeFlexible();
    } catch (e) {
      debugPrint('Play güncellemesi kurulamadı: $e');
    }
  }
}

final playUpdateControllerProvider = Provider<PlayUpdateController>(PlayUpdateController.new);

const kPlayUpdateReadyMessage = 'Yeni sürüm indi.';
const kPlayUpdateRestartLabel = 'Yeniden başlat';
const kPlayUpdateDownloadingMessage = 'Yeni sürüm indiriliyor; bitince haber vereceğim.';
const kPlayUpdateCheckFailedMessage = "Google Play'e ulaşılamadı. Bağlantını kontrol edip tekrar dene.";

/// İnen güncellemeyi kurmak için çubuk. Kalıcı DEĞİLDİR (bildirim çubuklarını
/// arkasında bekletmesin); kurulana kadar her öne gelişte yeniden gösterilir.
void showPlayRestartPrompt(PlayUpdateController controller) {
  final messenger = rootScaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: const Text(kPlayUpdateReadyMessage),
        duration: const Duration(seconds: 10),
        persist: false,
        action: SnackBarAction(label: kPlayUpdateRestartLabel, onPressed: controller.completeUpdate),
      ),
    );
}

/// Açılışta ve öne gelişte Play'e sorar (zorunlu güncelleme bekliyorsa her
/// öne gelişte, değilse 6 saatte bir). AppUpdateWatcher'ın Play karşılığı.
class PlayUpdateWatcher extends ConsumerStatefulWidget {
  const PlayUpdateWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PlayUpdateWatcher> createState() => _PlayUpdateWatcherState();
}

class _PlayUpdateWatcherState extends ConsumerState<PlayUpdateWatcher> with WidgetsBindingObserver {
  late final bool _supported = ref.read(playUpdateSupportedProvider);
  bool _readyToInstall = false;

  PlayUpdateController get _controller => ref.read(playUpdateControllerProvider);

  @override
  void initState() {
    super.initState();
    if (!_supported) return;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_readyToInstall || _controller.mandatoryPending || _controller.isStale) _check();
  }

  Future<void> _check() async {
    if (!mounted) return;
    final status = await _controller.run(manual: false);
    if (!mounted) return;
    _readyToInstall = status == PlayUpdateStatus.readyToInstall;
    if (_readyToInstall) showPlayRestartPrompt(_controller);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
