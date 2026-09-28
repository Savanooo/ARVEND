import 'package:flutter/material.dart';

import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_data_row.dart';
import '../../../../core/widgets/skeleton_box.dart';

/// Web ile aynı salt-okunur açıklaması (CostCodesManager.tsx).
const kCostCodesReadOnlyText =
    'Maliyet kodlarını yalnızca görüntüleyebilirsin; eklemek veya düzenlemek için rolünde '
    '"Maliyet kodu kataloğunu yönetme" izni olmalı.';

const kCostCodesNoAccessText =
    'Maliyet kodlarını görüntüleme yetkin yok. Yöneticinden rolüne "Maliyet kodu kataloğunu görüntüleme" '
    'iznini eklemesini isteyebilirsin.';

/// Yazma işlemlerinde gösterilecek metin: 403 sabit bir cümleye çevrilir,
/// diğer hatalarda backend'in (Türkçe) mesajı gösterilir.
String costCodeErrorText(Object error) {
  if (error is ApiException) {
    return error.isForbidden ? 'Bu işlem için yetkin yok.' : error.message;
  }
  return 'Beklenmeyen bir hata oluştu.';
}

bool isCostCodeForbidden(Object? error) => error is ApiException && error.isForbidden;

/// "Yalnızca görüntüleyebilirsin" kutusu -- ortak [ReadOnlyNotice].
class CostCodeReadOnlyNotice extends StatelessWidget {
  const CostCodeReadOnlyNotice({super.key});

  @override
  Widget build(BuildContext context) => const ReadOnlyNotice(kCostCodesReadOnlyText);
}

/// İzin yok (okuma izni hiç yok ya da sunucu 403 döndü) -- ekran ÇÖKMEZ,
/// ortak [NoAccessView]. Kaydırılabilir: pull-to-refresh bu durumda da çalışır.
class CostCodeNoAccessView extends StatelessWidget {
  const CostCodeNoAccessView({super.key});

  @override
  Widget build(BuildContext context) => const NoAccessView(message: kCostCodesNoAccessText, scrollable: true);
}

/// Detay satırı -- ortak `AppDataRow` düzeni; uzun değer kesilmez, boş
/// değer soluk "—".
class CostCodeInfoRow extends StatelessWidget {
  const CostCodeInfoRow({super.key, required this.label, this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final text = value ?? '';
    return AppDataRow(
      label: label,
      value: text.isEmpty ? '—' : text,
      valueColor: text.isEmpty ? AppColors.textMuted : null,
      multiline: true,
    );
  }
}

/// Liste yüklenirken iskelet.
class CostCodeListSkeleton extends StatelessWidget {
  const CostCodeListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        const SkeletonBox(height: 16, width: 120, radius: 4),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < 6; i++) ...[
          const SkeletonBox(height: 60, radius: AppRadius.card),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

/// Arşivle/Etkinleştir onayı -- web `useConfirmDialog` ile aynı metinler.
Future<bool> confirmCostCodeAction(
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
