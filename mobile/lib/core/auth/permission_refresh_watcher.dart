import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Kullanıcının yetkilerini (rol, kişiye özel izinler) uygulama öne
/// gelince ve uygulama açıkken her [interval]'da bir sunucudan tazeler
/// (bkz. AuthController.recheckPermissions). Eskiden izin listesi yalnızca
/// açılışta okunuyordu: Android süreci günlerce yaşayabildiği için web'den
/// verilen yetki telefonda görünmüyor, geri alınan yetkinin düğmeleri 403'e
/// basıyordu. Arka plandayken zamanlayıcı durur (ağ harcanmaz).
class PermissionRefreshWatcher extends ConsumerStatefulWidget {
  const PermissionRefreshWatcher({super.key, required this.child, this.interval = defaultInterval});

  static const defaultInterval = Duration(minutes: 5);

  final Widget child;
  final Duration interval;

  @override
  ConsumerState<PermissionRefreshWatcher> createState() => _PermissionRefreshWatcherState();
}

class _PermissionRefreshWatcherState extends ConsumerState<PermissionRefreshWatcher> {
  late final AppLifecycleListener _lifecycle;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume, onPause: _stop);
    _start();
  }

  @override
  void dispose() {
    _stop();
    _lifecycle.dispose();
    super.dispose();
  }

  void _onResume() {
    _check();
    _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.interval, (_) => _check());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _check() {
    if (!mounted) return;
    unawaited(ref.read(authControllerProvider.notifier).recheckPermissions());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
