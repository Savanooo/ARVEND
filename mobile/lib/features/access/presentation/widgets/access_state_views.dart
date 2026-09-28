import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/skeleton_box.dart';

// Ortak yetki görünümleri (NoAccessView, ReadOnlyNotice) core'dadır; bu
// dosyayı içe aktaran ekranlar onları da buradan alır.
export '../../../../core/widgets/access_notices.dart';

/// Yönetim ekranlarının (Personel, Kullanıcılar, Roller & Yetkiler) ortak
/// durum görünümleri. Ekranlar izni yoksa API'yi HİÇ çağırmadan
/// [NoAccessView] gösterir; yine de backend 403 dönerse (ör. yetki oturum
/// açıkken daraltıldı) [GuardedAsyncView] çökmek yerine aynı açık mesajı
/// verir.

const kForbiddenMessage =
    'Bu bilgiyi görmek için yetkin yok. Yetkilerin değişmiş olabilir; gerekiyorsa firma yöneticine başvur.';

/// `AsyncStateView` + 403'e özel açık mesaj. Diğer hatalar/yükleniyor/boş
/// durumları aynen ortak bileşene bırakılır.
class GuardedAsyncView<T> extends StatelessWidget {
  const GuardedAsyncView({
    super.key,
    required this.value,
    required this.data,
    this.onRetry,
    this.isEmpty,
    this.emptyBuilder,
    this.loadingBuilder,
    this.forbiddenMessage = kForbiddenMessage,
    this.keepDataWhileReloading = false,
  });

  /// Bağımlı bir sağlayıcı tazelenirken (ör. aşağı çekip yenileme rol
  /// listesini yeniden çeker) eldeki veri gösterilmeye devam eder; düzenleyici
  /// ekranlar sökülüp kaydedilmemiş seçimler silinmez.
  final bool keepDataWhileReloading;

  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) data;
  final Future<void> Function()? onRetry;
  final bool Function(T data)? isEmpty;
  final Widget Function(BuildContext context)? emptyBuilder;

  /// İlk yüklemede (henüz veri yokken) gösterilecek iskelet; verilmezse
  /// ortak dönen gösterge.
  final Widget Function(BuildContext context)? loadingBuilder;
  final String forbiddenMessage;

  @override
  Widget build(BuildContext context) {
    final error = value.hasValue ? null : value.error;
    if (!value.isLoading && error is ApiException && error.isForbidden) {
      return NoAccessView(message: forbiddenMessage, scrollable: true);
    }
    if (loadingBuilder != null && value.isLoading && !value.hasValue && !value.hasError) {
      return loadingBuilder!(context);
    }
    // Veri, yenilemede de AYNI ağaç yolundan (AsyncStateView içinden)
    // çizilir: yol değişseydi altındaki durumlu düzenleyiciler sökülüp
    // yeniden kurulur, kaydedilmemiş seçimler silinirdi.
    final effective = keepDataWhileReloading && value.isLoading && value.hasValue && !value.hasError
        ? AsyncData<T>(value.requireValue)
        : value;
    return AsyncStateView<T>(
      value: effective,
      data: data,
      onRetry: onRetry,
      isEmpty: isEmpty,
      emptyBuilder: emptyBuilder,
    );
  }
}

/// Liste ekranlarının ilk yükleme iskeleti -- satır kartlarıyla aynı
/// yükseklikte kutular ("0" ya da boş liste yanıp sönmesin).
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.count = 6, this.itemHeight = 68});

  final int count;
  final double itemHeight;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
      children: [
        const SkeletonBox(height: 14, width: 120, radius: 6),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < count; i++) ...[
          SkeletonBox(height: itemHeight, radius: AppRadius.card),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

/// Sağlayıcıyı tazeler ve yeni veri gelene kadar bekler -- aşağı çekip
/// yenileme göstergesi erken kapanmasın. Hata yutulur; ekran gövdesi
/// hatayı zaten gösterir.
Future<void> refreshAndWait(WidgetRef ref, List<ProviderOrFamily> invalidate, Future<Object?> Function() wait) async {
  for (final p in invalidate) {
    ref.invalidate(p);
  }
  try {
    await wait();
  } catch (_) {
    // Hata gövdede gösterilir.
  }
}

/// Onay penceresi -- yıkıcı işlem (pasifleştirme) kırmızı tonda.
Future<bool> confirmAccessAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool danger = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
        TextButton(
          style: danger ? TextButton.styleFrom(foregroundColor: AppColors.danger) : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Boş/hata durumunda da aşağı çekip yenilemenin çalışması için içeriği
/// ekranı dolduran kaydırılabilir bir alana yerleştirir.
class FillScrollable extends StatelessWidget {
  const FillScrollable({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight.isFinite ? constraints.maxHeight : 0),
          child: Center(child: child),
        ),
      ),
    );
  }
}

enum NoteTone { info, warning, danger, success }

/// Kart içi kısa bilgi/uyarı notu (ör. "yalnızca görüntüleyebilirsin").
class InfoNote extends StatelessWidget {
  const InfoNote(this.text, {super.key, this.tone = NoteTone.info, this.icon});

  final String text;
  final NoteTone tone;
  final IconData? icon;

  Color get _color => switch (tone) {
    NoteTone.info => AppColors.textMuted,
    NoteTone.warning => AppColors.warning,
    NoteTone.danger => AppColors.danger,
    NoteTone.success => AppColors.success,
  };

  IconData get _icon =>
      icon ??
      switch (tone) {
        NoteTone.info => Icons.info_outline,
        NoteTone.warning => Icons.warning_amber_rounded,
        NoteTone.danger => Icons.error_outline,
        NoteTone.success => Icons.check_circle_outline,
      };

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: tone == NoteTone.info ? 0.06 : 0.08),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_icon, size: 16, color: color),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: AppTypography.helper.copyWith(
                color: tone == NoteTone.info ? AppColors.textMuted : AppColors.textPrimary,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ad soyaddan iki harfli yuvarlak rozet. Türkçe büyük harf kuralı
/// (i -> İ, ı -> I) elle uygulanır -- `toUpperCase()` "i"yi bozar.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({super.key, required this.name, this.size = 36, this.muted = false});

  final String name;
  final double size;
  final bool muted;

  static String initialsOf(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final letters = parts.length == 1 ? [parts.first[0]] : [parts.first[0], parts.last[0]];
    return letters.map(_upperTr).join();
  }

  static String _upperTr(String ch) => switch (ch) {
    'i' => 'İ',
    'ı' => 'I',
    _ => ch.toUpperCase(),
  };

  @override
  Widget build(BuildContext context) {
    final color = muted ? AppColors.textMuted : AppColors.gold;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
      child: Text(
        initialsOf(name),
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: size * 0.36),
      ),
    );
  }
}
