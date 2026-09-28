import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/domain/user.dart';
import '../auth/auth_controller.dart';
import 'update_controller.dart';
import 'update_presenter.dart';

/// Otomatik güncelleme denetiminin zamanlaması (yalnızca Android):
/// - açılışta BİR KEZ (giriş ekranında da -- sürüm ucu herkese açık),
/// - uygulama öne geldiğinde, son başarılı denetim 6 saatten eskiyse,
/// - girişten sonra: kullanıcı oturumsuzken "Güncelle" dediyse ya da
///   güncelleme zorunluysa istem yeniden gösterilir (bilgi 6 saatten
///   eskiyse önce sunucuya yeniden sorularak).
///
/// Başarısız denetim SESSİZDİR. MaterialApp.router'ın `builder`'ında,
/// Navigator'ın ÜSTÜNDE durur; diyaloglar router'ın kök Navigator'ına açılır.
class AppUpdateWatcher extends ConsumerStatefulWidget {
  const AppUpdateWatcher({super.key, required this.navigatorKey, required this.child});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<AppUpdateWatcher> createState() => _AppUpdateWatcherState();
}

class _AppUpdateWatcherState extends ConsumerState<AppUpdateWatcher> with WidgetsBindingObserver {
  late final bool _supported = ref.read(updateSupportedProvider);
  UpdatePresenter? _presenter;

  UpdatePresenter get _updatePresenter => _presenter ??= UpdatePresenter(
        container: ProviderScope.containerOf(context, listen: false),
        navigatorContext: () => widget.navigatorKey.currentContext,
      );

  UpdateController get _controller => ref.read(updateControllerProvider.notifier);

  bool get _loggedIn => ref.read(authControllerProvider).valueOrNull != null;

  @override
  void initState() {
    super.initState();
    if (!_supported) return;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoCheck(UpdateCheckTrigger.startup));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResume();
  }

  Future<void> _autoCheck(UpdateCheckTrigger trigger) async {
    if (!mounted) return;
    final result = await _controller.check(trigger: trigger);
    if (!mounted || !result.shouldPrompt) return;
    // Oturumsuzken "Güncelle" denmiş ve kullanıcı henüz giriş yapmamışsa
    // istem giriş formunu tekrar tekrar kapatmasın -- girişte gösterilir.
    if (ref.read(updateControllerProvider).awaitingLogin && !_loggedIn) return;
    await _updatePresenter.present(result);
  }

  void _onResume() {
    if (!mounted) return;
    final stale = _controller.isStale;
    if (_controller.isPresenting) {
      // İstem/indirme açıkken yeni istem açılmaz ama bilgi yine tazelenir:
      // zorunlu istem yeniden açılırken ve indirme sırasında elde GÜNCEL
      // kayıt olsun (bu arada yeni sürüm yayınlanmış olabilir).
      if (stale) unawaited(_controller.check(trigger: UpdateCheckTrigger.resume));
      return;
    }
    // Bilgi eskiyse önce sunucuya sorulur; zorunlu güncelleme hâlâ varsa
    // denetimin kendisi istemi açar.
    if (stale) {
      _autoCheck(UpdateCheckTrigger.resume);
      return;
    }
    // Zorunlu güncelleme bekliyorsa (ör. kurulum ekranında iptal edildi)
    // yeniden istek atmadan istem tekrar açılır.
    final cached = _controller.cachedAvailable;
    if (cached != null && cached.mandatory && (_loggedIn || !ref.read(updateControllerProvider).awaitingLogin)) {
      _updatePresenter.present(cached);
    }
  }

  Future<void> _onLogin() async {
    if (!mounted || _controller.isPresenting) return;
    final awaitingLogin = ref.read(updateControllerProvider).awaitingLogin;
    var cached = _controller.cachedAvailable;
    if (cached == null || !(awaitingLogin || cached.mandatory)) return;
    // Giriş ekranında saatlerce beklenmiş olabilir: bilgi eskiyse istem
    // gösterilmeden önce sunucuya yeniden sorulur (sorulamazsa son bilinen
    // kayıt kullanılır; indirme diyaloğu yine kendini düzeltir).
    if (_controller.isStale) {
      await _controller.check(trigger: UpdateCheckTrigger.login);
      if (!mounted || _controller.isPresenting) return;
      cached = _controller.cachedAvailable;
      if (cached == null) {
        _controller.setAwaitingLogin(false);
        return;
      }
      if (!(awaitingLogin || cached.mandatory)) return;
    }
    await _updatePresenter.present(cached);
  }

  @override
  Widget build(BuildContext context) {
    if (_supported) {
      ref.listen<AsyncValue<User?>>(authControllerProvider, (previous, next) {
        final wasLoggedIn = previous?.valueOrNull != null;
        final isLoggedIn = next.valueOrNull != null;
        if (!wasLoggedIn && isLoggedIn) _onLogin();
      });
    }
    return widget.child;
  }
}
