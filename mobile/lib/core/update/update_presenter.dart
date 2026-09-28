import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/domain/user.dart';
import '../auth/auth_controller.dart';
import 'update_controller.dart';
import 'update_progress_dialog.dart';
import 'update_prompt_dialog.dart';

const kUpdateLoginRequiredMessage = 'Güncellemeyi indirmek için önce giriş yap.';
const kUpdateUpToDateMessage = 'Güncel sürümü kullanıyorsun';
const kUpdateCheckFailedMessage = 'Sürüm bilgisi alınamadı. Bağlantını kontrol edip tekrar dene.';

/// Güncelleme istemini ve indirme akışını gösteren TEK yer -- açılış/öne
/// gelme denetimi (AppUpdateWatcher) ile "Güncellemeleri denetle" (Hakkında
/// ekranı) aynı kodu kullanır.
///
/// Widget ömrüne BAĞLI DEĞİLDİR: diyaloglar kök Navigator'ın context'iyle
/// açılır, provider'lar uygulama boyunca yaşayan ProviderContainer'dan
/// okunur -- akış sürerken çağıran ekran kapansa bile yarıda kalmaz.
class UpdatePresenter {
  UpdatePresenter({required this._container, required this._navigatorContext});

  /// Ekrandan çağrılırken: kök Navigator + uygulamanın ProviderContainer'ı.
  factory UpdatePresenter.of(BuildContext context) {
    final navigator = Navigator.of(context, rootNavigator: true);
    return UpdatePresenter(
      container: ProviderScope.containerOf(context, listen: false),
      navigatorContext: () => navigator.mounted ? navigator.context : null,
    );
  }

  /// Zorunlu istem, sayfa yığını değiştiği için (ör. oturum düştü, giriş
  /// ekranına dönüldü) kapanırsa yeniden açılır -- sonsuz döngüye karşı üst
  /// sınır.
  static const _maxReshows = 5;

  final ProviderContainer _container;
  final BuildContext? Function() _navigatorContext;

  UpdateController get _controller => _container.read(updateControllerProvider.notifier);

  bool get _loggedIn => _container.read(authControllerProvider).valueOrNull != null;

  /// "Güncellemeleri denetle": ertelemeyi dinlemez, sonucu her durumda
  /// kullanıcıya söyler. [onChecked] sunucu cevap verir vermez (istem
  /// açılmadan ÖNCE) çağrılır -- çağıran ekran yükleniyor göstergesini
  /// kapatabilsin.
  Future<void> checkManually({VoidCallback? onChecked}) async {
    final result = await _controller.check(trigger: UpdateCheckTrigger.manual);
    onChecked?.call();
    switch (result.status) {
      case UpdateCheckStatus.unsupported:
        return;
      case UpdateCheckStatus.failed:
        _showMessage(kUpdateCheckFailedMessage);
      case UpdateCheckStatus.upToDate:
        final installed = result.installed;
        _showMessage(installed == null ? kUpdateUpToDateMessage : '$kUpdateUpToDateMessage · ${installed.label}');
      case UpdateCheckStatus.available:
        if (_controller.isPresenting) return;
        await present(result);
    }
  }

  /// İstemi gösterir; "Güncelle" denirse indirme diyaloğunu açar. Zaten
  /// bir istem/akış açıksa hiçbir şey yapmaz.
  Future<void> present(UpdateCheckResult initial) async {
    if (initial.release == null || !_controller.tryBeginPresentation()) return;
    try {
      _controller.setAwaitingLogin(false);
      var result = initial;
      var reshows = 0;
      while (true) {
        final release = result.release!;
        await _whenRouteSettled();
        final promptContext = _navigatorContext();
        if (promptContext == null || !promptContext.mounted) return;
        final choice = await showDialog<UpdatePromptChoice>(
          context: promptContext,
          barrierDismissible: !result.mandatory,
          builder: (_) => UpdatePromptDialog(
            release: release,
            installed: result.installed,
            mandatory: result.mandatory,
          ),
        );

        if (choice == UpdatePromptChoice.later) {
          await _controller.postpone(release);
          return;
        }
        if (choice == null) {
          // Normal istem: dışına dokunularak kapatıldı -- erteleme SAYILMAZ,
          // bir sonraki denetimde yine sorulur. Zorunlu istem kullanıcı
          // tarafından kapatılamaz; null ancak sayfa yığını değişince gelir.
          if (!result.mandatory || ++reshows > _maxReshows) return;
          final next = await _stillMandatory();
          if (next == null) return;
          result = next;
          continue;
        }

        // "Güncelle"
        if (!_loggedIn) {
          _requireLogin();
          return;
        }
        final flowContext = _navigatorContext();
        if (flowContext == null || !flowContext.mounted) return;
        final outcome = await showDialog<UpdateFlowResult>(
          context: flowContext,
          barrierDismissible: false,
          builder: (_) => UpdateProgressDialog(
            release: release,
            service: _container.read(updateInstallServiceProvider),
            // İndirme ucu hep GÜNCEL APK'yı verir; kayıt eskimişse diyalog
            // sürüm bilgisini bununla yeniden sorar (ertelemeyi dinlemez).
            recheck: () => _controller.check(trigger: UpdateCheckTrigger.manual),
          ),
        );
        if (outcome == UpdateFlowResult.loginRequired) {
          _requireLogin();
          return;
        }
        if (outcome == UpdateFlowResult.noUpdate) {
          _showMessage(kUpdateUpToDateMessage);
          return;
        }
        // Zorunlu güncellemede istem hep geri gelir: kurulum ekranı açıldıysa
        // onun ARKASINDA bekler (kurulum iptal edilirse uygulama yine
        // kilitli kalır), iptal edildiyse hemen yeniden sorulur.
        if (!result.mandatory) return;
        if (outcome == null && ++reshows > _maxReshows) return;
        final next = await _stillMandatory();
        if (next == null) return;
        result = next;
      }
    } finally {
      _controller.endPresentation();
    }
  }

  /// Zorunlu istem yeniden açılmadan önce: elimizdeki bilgi 6 saatten
  /// eskiyse sunucuya yeniden sorulur (bu arada yeni sürüm yayınlanmış,
  /// `min_build` düşürülmüş ya da yayın geri çekilmiş olabilir). Hâlâ
  /// zorunlu bir güncelleme varsa GÜNCEL kaydıyla döner; yoksa null --
  /// istem bir daha açılmaz. Sorulamazsa son bilinen kayıt kullanılır.
  Future<UpdateCheckResult?> _stillMandatory() async {
    if (_controller.isStale) await _controller.check(trigger: UpdateCheckTrigger.resume);
    final latest = _controller.cachedAvailable;
    return latest != null && latest.mandatory ? latest : null;
  }

  void _requireLogin() {
    _controller.setAwaitingLogin(true);
    _showMessage(kUpdateLoginRequiredMessage);
  }

  void _showMessage(String message) {
    final context = _navigatorContext();
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Oturum henüz çözülmemişse (açılışta GET /auth/me sürerken) bekler ve
  /// router'ın yönlendirmesinin (ör. /giris -> /ana-sayfa) uygulanacağı
  /// kareyi geçer -- aksi halde diyalog kaldırılacak sayfanın üstünde açılıp
  /// yönlendirmeyle birlikte kaybolurdu.
  Future<void> _whenRouteSettled() async {
    if (_container.read(authControllerProvider).isLoading) {
      final settled = Completer<void>();
      final sub = _container.listen<AsyncValue<User?>>(authControllerProvider, (_, next) {
        if (!next.isLoading && !settled.isCompleted) settled.complete();
      });
      if (!_container.read(authControllerProvider).isLoading && !settled.isCompleted) settled.complete();
      await settled.future;
      sub.close();
    }
    // Yönlendirme auth değişikliğinden sonraki karede işlenir, yeni sayfa
    // yığını bir sonrakinde kurulur -- iki kare beklemek yeterli.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }
}
