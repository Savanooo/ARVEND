import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_colors.dart';

/// Alttan açılan sayfaların (form, seçici, filtre) tek açılış noktası: üstte
/// çekme çubuğu, aşağı çekince kapanır.
///
/// Neden: formların çoğunda sürükleyerek kapatma kapalıydı, çünkü Flutter
/// sürükleyerek kapatmada sayfanın PopScope'una hiç bakmaz (doğrudan
/// Navigator.pop): kayıt sürerken kapanırsa kayıt oluşur ama çağıran sonucu
/// alamaz, liste tazelenmezdi. Ama neredeyse tam ekran açılan bir formdan
/// çıkmanın tek yolu telefonun geri hareketi kalıyordu; kullanıcı "Masraf
/// Ekle"den zor çıktı.
///
/// Şimdi sürükleme hep açık. Sayfadaki UnsavedChangesScope kayıt sürüyor ya
/// da kaydedilmemiş değişiklik var derse ([SheetDragLock]) sürükleme sayfayı
/// doğrudan kapatmaz, geri hareketiyle aynı yoldan (`maybePop`) gider:
/// "Kaydediliyor" uyarısı ya da "çıkılsın mı" onayı.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
}) {
  final lock = SheetDragLock();
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    builder: (sheetContext) => _SheetDragLockScope(
      lock: lock,
      child: _SheetBody(lock: lock, builder: builder),
    ),
  );
}

/// Sayfanın içindeki UnsavedChangesScope'lar "şu an sürükleyerek kapatma"
/// der; biri bile derse sayfa kilitlidir (aynı sayfada birden çok kapsam
/// olabilir).
class SheetDragLock extends ValueNotifier<bool> {
  SheetDragLock() : super(false);

  final _holders = <Object>{};

  static SheetDragLock? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_SheetDragLockScope>()?.lock;

  void hold(Object holder, bool locked) {
    final changed = locked ? _holders.add(holder) : _holders.remove(holder);
    if (changed) _publish();
  }

  void release(Object holder) {
    if (_holders.remove(holder)) _publish();
  }

  // Kapsamlar build/dispose sırasında çağırır; dinleyiciyi o anda
  // tetiklemek "build sırasında setState" hatası olurdu.
  void _publish() {
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => value = _holders.isNotEmpty,
    );
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}

class _SheetDragLockScope extends InheritedWidget {
  const _SheetDragLockScope({required this.lock, required super.child});

  final SheetDragLock lock;

  @override
  bool updateShouldNotify(_SheetDragLockScope oldWidget) =>
      lock != oldWidget.lock;
}

class _SheetBody extends StatefulWidget {
  const _SheetBody({required this.lock, required this.builder});

  final SheetDragLock lock;
  final WidgetBuilder builder;

  @override
  State<_SheetBody> createState() => _SheetBodyState();
}

class _SheetBodyState extends State<_SheetBody> {
  /// Kilitliyken bu kadar aşağı çekmek ya da hızlı fırlatmak "kapat" sayılır.
  static const _closeDistance = 56.0;
  static const _closeVelocity = 500.0;

  double _dragged = 0;

  void _onDragEnd(DragEndDetails details) {
    final close =
        _dragged > _closeDistance ||
        (details.primaryVelocity ?? 0) > _closeVelocity;
    _dragged = 0;
    if (close) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DragHandle(),
        Flexible(child: Builder(builder: widget.builder)),
      ],
    );
    return ValueListenableBuilder<bool>(
      valueListenable: widget.lock,
      // Kilitliyken dikey sürüklemeyi içerdeki dinleyici kazanır (sayfanın
      // kendi sürükleme dinleyicisinden önce yarışa girer) ve kapatmayı
      // maybePop'a çevirir. Dinleyici HEP ağaçta durur, yalnızca geri
      // çağrıları açılıp kapanır: ağaç yapısı değişseydi kilit her
      // değiştiğinde formun durumu (seçilen değerler) sıfırlanırdı.
      builder: (context, locked, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: locked ? (_) => _dragged = 0 : null,
        onVerticalDragUpdate: locked ? (d) => _dragged += d.delta.dy : null,
        onVerticalDragEnd: locked ? _onDragEnd : null,
        child: child,
      ),
      child: body,
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        key: const Key('sheet-drag-handle'),
        margin: const EdgeInsets.only(top: 10),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.textMuted.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
