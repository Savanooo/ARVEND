import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../features/notifications/data/notifications_providers.dart';
import '../auth/auth_controller.dart';
import 'push_messaging.dart';

/// Uygulamanın kökündeki ScaffoldMessenger -- açıkken gelen bildirim alt
/// bant olarak gösterilir (Android uygulama öndeyken bildirimi kendisi
/// göstermez).
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Telefona bildirimin uygulama tarafı:
/// - oturum açılınca izin ister ve telefonu sunucuya kaydeder (anahtar
///   yenilenince yeniden),
/// - uygulama açıkken gelen bildirimde zil sayacını tazeler ve alt bant
///   gösterir,
/// - dokunulan bildirimin hedef ekranını açar (oturum yoksa girişten sonra).
class PushWatcher extends ConsumerStatefulWidget {
  const PushWatcher({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<PushWatcher> createState() => _PushWatcherState();
}

class _PushWatcherState extends ConsumerState<PushWatcher> {
  final _subs = <StreamSubscription<Object?>>[];
  String? _pendingTarget;
  String? _registeredFor;

  PushMessaging get _push => ref.read(pushMessagingProvider);
  bool get _loggedIn => ref.read(authControllerProvider).valueOrNull != null;

  @override
  void initState() {
    super.initState();
    _subs.add(_push.onForegroundMessage.listen(_onForeground));
    _subs.add(_push.onMessageOpenedApp.listen((m) => _open(m.actionTarget)));
    _subs.add(_push.onTokenRefresh.listen((t) {
      if (_loggedIn) _register(t);
    }));
    unawaited(_push.initialMessage().then((m) {
      if (m != null) _open(m.actionTarget);
    }));
    // Uygulama oturum açık halde başladıysa (çerez geçerli) dinleyici
    // değişiklik görmez -- ilk karede kaydet.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAuthChanged());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    final user = ref.read(authControllerProvider).valueOrNull;
    if (user == null) {
      _registeredFor = null;
      return;
    }
    if (_registeredFor != user.id) {
      _registeredFor = user.id;
      unawaited(_registerCurrent());
    }
    final target = _pendingTarget;
    if (target != null) {
      _pendingTarget = null;
      _open(target);
    }
  }

  Future<void> _registerCurrent() async {
    try {
      await _push.requestPermission();
      final token = await _push.token();
      if (token != null) await _register(token);
    } catch (e) {
      debugPrint('Bildirim: kayıt yapılamadı: $e');
    }
  }

  Future<void> _register(String token) async {
    var version = '';
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    try {
      await ref.read(pushRepositoryProvider).register(token, appVersion: version);
    } catch (e) {
      // Bildirim kaydı başarısız diye uygulama durmaz; bir sonraki açılışta
      // yeniden denenir.
      debugPrint('Bildirim: cihaz sunucuya kaydedilemedi: $e');
    }
  }

  void _onForeground(PushMessage m) {
    ref.invalidate(unreadNotificationCountProvider);
    ref.invalidate(notificationsListProvider);
    final messenger = rootScaffoldMessengerKey.currentState;
    if (messenger == null || m.title.isEmpty) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(m.body.isEmpty ? m.title : '${m.title}\n${m.body}', maxLines: 3, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 5),
        action: m.actionTarget.isEmpty
            ? null
            : SnackBarAction(label: 'Aç', onPressed: () => _open(m.actionTarget)),
      ),
    );
  }

  void _open(String target) {
    if (target.isEmpty || !target.startsWith('/')) return;
    if (!_loggedIn) {
      _pendingTarget = target;
      return;
    }
    ref.invalidate(unreadNotificationCountProvider);
    widget.router.push(target);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authControllerProvider, (_, _) => _onAuthChanged());
    return widget.child;
  }
}
