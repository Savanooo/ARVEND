import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_update/in_app_update.dart' as iau;
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../push/push_watcher.dart' show rootScaffoldMessengerKey;
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_status_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/app_buttons.dart';
import 'update_controller.dart';
import 'update_prompt_dialog.dart' show UpdateNotice;

/// Google Play sürümünde güncelleme: Play'in kendi uygulama içi güncelleme
/// API'si (In-App Updates). Sideload yapısındaki kendi güncelleyicimizin
/// (update_controller.dart) Play'deki karşılığı -- Play, uygulamanın kendini
/// Play dışından güncellemesini yasaklıyor ama bu API'ye izin veriyor.
///
/// - Normal yeni sürüm: Play'in kendi onay penceresi açılır (otomatik
///   denetimde aynı sürüm için günde en fazla bir kez), indirme arka planda
///   sürer; inince "Yeniden başlat" çubuğu çıkar.
/// - Zorunlu: kurulu build sunucudaki `min_build`'in altındaysa (backend
///   `play.json`; sideload'un `latest.json`'ı da aynı versionCode dizisini
///   kullanır) Play'in tam ekran güncellemesi açılır. Kullanıcı vazgeçerse
///   ya da pencere açılamazsa uygulama kapatılamayan "Güncelleme gerekli"
///   ekranında bekler (Güncelle / Google Play'de aç); ekran açıkken öne
///   gelişte Play'in penceresi kendiliğinden açılmaz, yalnızca zorunluluğun
///   sürüp sürmediğine bakılır.
/// - Play'e ya da sunucuya ulaşılamazsa (uygulama Play'den kurulmamış,
///   derleme Play'e bağlı değil, ağ yok) hiçbir şey kilitlenmez.
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

  /// Bu sürüm son 24 saatte zaten önerildi -- otomatik denetimde sorulmaz.
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

  /// Güncelleme zorunlu, Play onu sunuyor ama başlatılamadı (kullanıcı Play'in
  /// penceresinden vazgeçti ya da pencere açılamadı): uygulama kapatılamayan
  /// "Güncelleme gerekli" ekranında bekler (PlayUpdateWatcher). Play'e ya da
  /// sunucuya ulaşılamayan her durumda false -- kimse kilitlenmez.
  bool updateRequired = false;

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
      // Uygulama Play'den kurulmamış (ör. geliştirici yapısı), Play Hizmetleri
      // yok ya da ağ yok: sessizce geçilir, uygulama kilitlenmez.
      debugPrint('Play güncelleme denetimi başarısız: $e');
      updateRequired = false;
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
      // Sunucu zorunlu dese bile Play'de kurulacak sürüm yoksa (ör. kademeli
      // dağıtım bu telefona henüz ulaşmadı) kilitlenmez.
      mandatoryPending = false;
      updateRequired = false;
      return PlayUpdateStatus.upToDate;
    }

    final mandatory = await _isMandatory();
    mandatoryPending = mandatory;
    onChecked?.call();

    if (mandatory) {
      final status = await _runMandatory(client, info);
      updateRequired = status != PlayUpdateStatus.started;
      return status;
    }
    updateRequired = false;
    if (info.inProgress) return PlayUpdateStatus.downloading;

    // Öneri, otomatik denetimde aynı sürüm için günde en fazla bir kez:
    // pencere açılmadan kaydedilir -- kullanıcı indirmeyi yarıda bıraksa ya
    // da pencere hata verse de aynı gün yeniden sorulmaz. Elle denetim
    // ("Güncellemeleri denetle") ertelemeye bakmaz; daha yeni bir sürüm
    // erteleme beklemeden sorulur.
    final versionCode = info.versionCode ?? 0;
    final store = _ref.read(updatePostponeStoreProvider);
    if (!manual) {
      if (await store.isPostponed(versionCode)) return PlayUpdateStatus.postponed;
      await store.postpone(versionCode);
    }

    if (info.flexibleAllowed) {
      switch (await client.startFlexible()) {
        case PlayUpdateOutcome.completed:
          return PlayUpdateStatus.readyToInstall;
        case PlayUpdateOutcome.denied:
          await store.postpone(versionCode);
          return PlayUpdateStatus.denied;
        case PlayUpdateOutcome.failed:
          return PlayUpdateStatus.failed;
      }
    }
    // Play arka planda indirmeye izin vermiyorsa tek yol tam ekran güncelleme.
    if (info.immediateAllowed) return _immediate(client);
    return PlayUpdateStatus.failed;
  }

  /// "Güncelleme gerekli" ekranı açıkken öne gelişte: Play'in penceresini
  /// AÇMADAN zorunluluğun sürüp sürmediğine bakar. Play'in tam ekranından
  /// her dönüşte pencere yeniden açılsaydı kullanıcı ekranı hiç göremeden
  /// döngüye girerdi; yeniden denemek "Güncelle" düğmesinin işidir. Play'e ya
  /// da sunucuya ulaşılamazsa ya da Play artık güncelleme sunmuyorsa ekran
  /// kalkar. Hata FIRLATMAZ.
  Future<bool> recheckRequired() async {
    if (_busy) return updateRequired;
    _busy = true;
    try {
      final PlayUpdateInfo info;
      try {
        info = await _ref.read(playUpdateClientProvider).check();
      } catch (e) {
        debugPrint('Play güncelleme denetimi başarısız: $e');
        return updateRequired = false;
      }
      _lastCheckedAt = _ref.read(updateClockProvider)();
      if (!info.available && !info.inProgress) {
        mandatoryPending = false;
        return updateRequired = false;
      }
      final mandatory = await _isMandatory();
      mandatoryPending = mandatory;
      return updateRequired = mandatory;
    } finally {
      _busy = false;
    }
  }

  /// Zorunlu güncelleme: Play'in tam ekran güncellemesi (yarım kaldıysa
  /// sürdürülür). Play buna izin vermiyorsa arka planda indirilip hemen
  /// kurulur. Erteleme hiç dinlenmez.
  Future<PlayUpdateStatus> _runMandatory(PlayUpdateClient client, PlayUpdateInfo info) async {
    if (info.inProgress || info.immediateAllowed) return _immediate(client);
    if (!info.flexibleAllowed) return PlayUpdateStatus.failed;
    switch (await client.startFlexible()) {
      case PlayUpdateOutcome.completed:
        await completeUpdate();
        return PlayUpdateStatus.started;
      case PlayUpdateOutcome.denied:
        return PlayUpdateStatus.denied;
      case PlayUpdateOutcome.failed:
        return PlayUpdateStatus.failed;
    }
  }

  Future<PlayUpdateStatus> _immediate(PlayUpdateClient client) async {
    return switch (await client.performImmediate()) {
      PlayUpdateOutcome.completed => PlayUpdateStatus.started,
      PlayUpdateOutcome.denied => PlayUpdateStatus.denied,
      PlayUpdateOutcome.failed => PlayUpdateStatus.failed,
    };
  }

  /// Kurulu build sunucudaki `min_build`'in altında (backend `play.json`;
  /// sideload yayını olmasa da döner). Sunucuya ulaşılamazsa zorunlu
  /// SAYILMAZ (kullanıcı kilitlenmez).
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

/// Uygulamanın Play sayfasını açar; açılamazsa false. Testler sahtesini verir.
typedef PlayStoreOpener = Future<bool> Function();

final playStoreOpenerProvider = Provider<PlayStoreOpener>(
  (ref) => () async {
    try {
      return await launchUrl(Uri.parse(AppConfig.playStoreUrl), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Google Play açılamadı: $e');
      return false;
    }
  },
);

const kPlayUpdateReadyMessage = 'Yeni sürüm indi.';
const kPlayUpdateRestartLabel = 'Yeniden başlat';
const kPlayUpdateDownloadingMessage = 'Yeni sürüm indiriliyor; bitince haber vereceğim.';
const kPlayUpdateCheckFailedMessage = "Google Play'e ulaşılamadı. Bağlantını kontrol edip tekrar dene.";
const kPlayUpdateRequiredTitle = 'Güncelleme gerekli';
const kPlayUpdateRequiredMessage =
    "Kullandığın sürüm artık desteklenmiyor. Devam etmek için uygulamayı Google Play'den güncelle.";
const kPlayUpdateRequiredUpdateLabel = 'Güncelle';
const kPlayUpdateRequiredStoreLabel = "Google Play'de aç";
const kPlayStoreOpenFailedMessage = "Google Play açılamadı. Play Store'da ARVEND'i arayıp güncelle.";

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
///
/// Zorunlu güncelleme başlatılamadıysa ([PlayUpdateController.updateRequired])
/// uygulamanın yerine kapatılamayan "Güncelleme gerekli" ekranı çıkar.
/// Uygulama ağacı arkada (görünmez) yaşamaya devam eder; geri tuşu ekranı
/// kapatmaz, uygulamayı arka plana alır.
class PlayUpdateWatcher extends ConsumerStatefulWidget {
  const PlayUpdateWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PlayUpdateWatcher> createState() => _PlayUpdateWatcherState();
}

class _PlayUpdateWatcherState extends ConsumerState<PlayUpdateWatcher> with WidgetsBindingObserver {
  late final bool _supported = ref.read(playUpdateSupportedProvider);
  bool _readyToInstall = false;
  bool _required = false;

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
    // Ekran açıkken Play'in penceresi kendiliğinden yeniden açılmaz (bkz.
    // PlayUpdateController.recheckRequired).
    if (_required) {
      _recheckRequired();
      return;
    }
    if (_readyToInstall || _controller.mandatoryPending || _controller.isStale) _check();
  }

  Future<void> _recheckRequired() async {
    final required = await _controller.recheckRequired();
    if (mounted && _required != required) setState(() => _required = required);
  }

  /// Geri tuşu: zorunlu güncelleme ekranı kapanmaz (arkadaki uygulamanın
  /// sayfaları da görünmeden geri gitmez), uygulama arka plana alınır. Bu
  /// gözcü router'ın geri tuşu dinleyicisinden ÖNCE kaydolur (router onun
  /// altında kurulur), bu yüzden geri tuşunu ilk o görür.
  @override
  Future<bool> didPopRoute() async {
    if (!_required) return false;
    await SystemNavigator.pop();
    return true;
  }

  Future<void> _check({bool manual = false}) async {
    if (!mounted) return;
    final status = await _controller.run(manual: manual);
    if (!mounted) return;
    _readyToInstall = status == PlayUpdateStatus.readyToInstall;
    if (_required != _controller.updateRequired) setState(() => _required = _controller.updateRequired);
    if (_readyToInstall) showPlayRestartPrompt(_controller);
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return widget.child;
    // Uygulama ağacı her durumda AYNI yerde kalır (durumu kaybolmasın);
    // zorunlu güncellemede görünmez, dokunulamaz, odak alamaz.
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: _required,
          child: TickerMode(enabled: !_required, child: ExcludeFocus(excluding: _required, child: widget.child)),
        ),
        if (_required)
          // Kendi Navigator'ı: ekran router'ın Navigator'ının ÜSTÜNDE durur
          // (Overlay/Tooltip için). MaterialApp'in HeroController'ı router'ın
          // Navigator'ına ait -- ikisi paylaşamaz.
          HeroControllerScope.none(
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => PlayUpdateRequiredScreen(onUpdate: () => _check(manual: true)),
              ),
            ),
          ),
      ],
    );
  }
}

/// Zorunlu güncelleme başlatılamadığında uygulamanın yerine çıkan,
/// kapatılamayan ekran. "Güncelle" Play'in tam ekran güncellemesini yeniden
/// açar; o da olmazsa "Google Play'de aç" uygulamanın Play sayfasını açar.
class PlayUpdateRequiredScreen extends ConsumerStatefulWidget {
  const PlayUpdateRequiredScreen({super.key, required this.onUpdate});

  final Future<void> Function() onUpdate;

  @override
  ConsumerState<PlayUpdateRequiredScreen> createState() => _PlayUpdateRequiredScreenState();
}

class _PlayUpdateRequiredScreenState extends ConsumerState<PlayUpdateRequiredScreen> {
  bool _busy = false;

  Future<void> _update() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onUpdate();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openStore() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (await ref.read(playStoreOpenerProvider)()) return;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(kPlayStoreOpenFailedMessage)));
  }

  @override
  Widget build(BuildContext context) {
    final installed = ref.watch(installedVersionProvider).valueOrNull;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.navDark,
                          borderRadius: BorderRadius.circular(AppRadius.card),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.system_update_outlined, color: AppColors.gold, size: 34),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      kPlayUpdateRequiredTitle,
                      textAlign: TextAlign.center,
                      style: AppTypography.pageTitle.copyWith(fontSize: 20),
                    ),
                    if (installed != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Kurulu sürüm: ${installed.label}',
                        textAlign: TextAlign.center,
                        style: AppTypography.metadata,
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    const UpdateNotice(
                      icon: Icons.error_outline,
                      color: AppStatusColors.warning,
                      text: kPlayUpdateRequiredMessage,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const Text(
                      'Bilgilerin sunucuda duruyor; güncellemeden sonra kaldığın yerden devam edersin.',
                      style: AppTypography.helper,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    PrimaryButton(
                      label: kPlayUpdateRequiredUpdateLabel,
                      icon: Icons.download_rounded,
                      loading: _busy,
                      onPressed: _update,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SecondaryButton(
                      label: kPlayUpdateRequiredStoreLabel,
                      icon: Icons.open_in_new,
                      onPressed: _openStore,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
