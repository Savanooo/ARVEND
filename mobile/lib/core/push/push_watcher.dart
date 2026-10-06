import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../features/notifications/data/notifications_providers.dart';
import '../auth/auth_controller.dart';
import '../auth/last_user_store.dart';
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
/// - dokunulan bildirimi okundu işaretler ve hedef ekranını açar (oturum
///   yoksa girişten sonra -- yalnızca bildirimin sahibi giriş yaparsa),
/// - uygulama öne gelince zil sayacını tazeler.
class PushWatcher extends ConsumerStatefulWidget {
  const PushWatcher({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<PushWatcher> createState() => _PushWatcherState();
}

/// Oturum yokken dokunulan bildirim. [ownerId]: bildirimin ait olduğu
/// kişi (bu telefonda en son oturum açmış kullanıcı); [awaitingRestore]:
/// uygulama bildirimle açıldı ve oturum henüz geri yükleniyordu -- çerezle
/// geri gelen oturum telefonun kayıtlı kullanıcısıdır.
typedef _PendingPush = ({PushMessage message, String? ownerId, bool awaitingRestore});

class _PushWatcherState extends ConsumerState<PushWatcher> {
  final _subs = <StreamSubscription<Object?>>[];
  late final AppLifecycleListener _lifecycle;
  _PendingPush? _pending;
  String? _registeredFor;

  /// Bu süreçte en son oturum açmış kullanıcı (çıkıştan sonra da tutulur).
  String? _lastUserId;

  /// Açılıştaki oturum geri yüklemesi (GET /auth/me) sonuçlandı mı. Sonraki
  /// yüklemeler (giriş isteği) "geri yükleme" sayılmaz.
  bool _restoreSettled = false;

  PushMessaging get _push => ref.read(pushMessagingProvider);
  bool get _loggedIn => ref.read(authControllerProvider).valueOrNull != null;

  @override
  void initState() {
    super.initState();
    _subs.add(_push.onForegroundMessage.listen(_onForeground));
    _subs.add(_push.onMessageOpenedApp.listen(_openMessage));
    _subs.add(_push.onTokenRefresh.listen((t) {
      if (_loggedIn) _register(t);
    }));
    unawaited(_push.initialMessage().then((m) {
      if (m != null) _openMessage(m);
    }));
    // Arka plandayken gelen bildirimler zildeki sayıya yansısın.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    // Uygulama oturum açık halde başladıysa (çerez geçerli) dinleyici
    // değişiklik görmez -- ilk karede kaydet.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAuthChanged());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _onResume() {
    if (!mounted || !_loggedIn) return;
    ref.invalidate(unreadNotificationCountProvider);
    ref.invalidate(notificationsListProvider);
  }

  void _onAuthChanged() {
    if (!mounted) return;
    final auth = ref.read(authControllerProvider);
    if (!auth.isLoading) _restoreSettled = true;
    final user = auth.valueOrNull;
    if (user == null) {
      _registeredFor = null;
      // Oturum geri gelmedi: bekleyen bildirim artık yalnızca sahibine.
      final pending = _pending;
      if (pending != null && pending.awaitingRestore && _restoreSettled) {
        unawaited(_bindToLastUser(pending.message));
      }
      return;
    }
    _lastUserId = user.id;
    if (_registeredFor != user.id) {
      _registeredFor = user.id;
      unawaited(_registerCurrent());
    }
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      // Oturum yokken dokunulan bildirim, girişte BAŞKA biri oturum açarsa
      // ona açılmaz (başkasının görev/proje bağlantısı) -- atılır.
      if (pending.awaitingRestore || pending.ownerId == user.id) _openMessage(pending.message);
    }
  }

  /// Oturum yokken dokunulan bildirimi girişe kadar beklet.
  void _holdUntilLogin(PushMessage m) {
    if (!_restoreSettled && ref.read(authControllerProvider).isLoading) {
      _pending = (message: m, ownerId: null, awaitingRestore: true);
      return;
    }
    unawaited(_bindToLastUser(m));
  }

  Future<void> _bindToLastUser(PushMessage m) async {
    final owner = _lastUserId ?? await ref.read(lastUserStoreProvider).lastUserId();
    if (!mounted) return;
    // Bu telefonda kimin oturumu olduğu bilinmiyorsa kime ait olduğu da
    // bilinemez -- bildirim atılır (zilde yine durur).
    _pending = owner == null ? null : (message: m, ownerId: owner, awaitingRestore: false);
    // Beklerken giriş yapılmış olabilir.
    if (_loggedIn) _onAuthChanged();
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
            : SnackBarAction(label: 'Aç', onPressed: () => _openMessage(m)),
      ),
    );
  }

  /// Dokunulan bildirim: okundu işaretlenir ve hedefi açılır.
  void _openMessage(PushMessage m) {
    if (!_loggedIn) {
      _holdUntilLogin(m);
      return;
    }
    unawaited(_markRead(m.notificationId));
    _open(m.actionTarget);
  }

  Future<void> _markRead(String notificationId) async {
    if (notificationId.isNotEmpty) {
      try {
        await ref.read(notificationsRepositoryProvider).markRead(notificationId);
      } catch (e) {
        // Okundu işaretlenemezse zilde okunmamış kalır; ekran yine açılır.
        debugPrint('Bildirim: okundu işaretlenemedi: $e');
      }
    }
    if (!mounted) return;
    ref.invalidate(unreadNotificationCountProvider);
    ref.invalidate(notificationsListProvider);
  }

  void _open(String target) {
    if (target.isEmpty || !target.startsWith('/')) return;
    // Hedef zaten açık olan ekransa (ör. duyurunun hedefi bildirim
    // listesi) ikinci bir kopyası açılmaz; liste yukarıda tazelendi.
    if (widget.router.routerDelegate.currentConfiguration.uri.path == target) return;
    widget.router.push(target);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authControllerProvider, (_, _) => _onAuthChanged());
    return widget.child;
  }
}
