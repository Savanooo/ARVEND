import 'package:flutter/material.dart';

import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_data_row.dart';
import '../../../../core/widgets/skeleton_box.dart';

/// Web ile aynı salt-okunur açıklaması (SuppliersManager.tsx).
const kSuppliersReadOnlyText =
    'Tedarikçileri yalnızca görüntüleyebilirsin; eklemek veya düzenlemek için rolünde '
    '"Tedarikçi oluşturma/düzenleme/arşivleme" izni olmalı.';

const kSuppliersNoAccessText =
    'Tedarikçileri görüntüleme yetkin yok. Yöneticinden rolüne "Tedarikçi kataloğunu görüntüleme" '
    'iznini eklemesini isteyebilirsin.';

/// Yazma işlemlerinde kullanıcıya gösterilecek metin. 403 (izin kaldırılmış
/// ya da eksik) sabit ve anlaşılır bir cümleye çevrilir; diğer hatalarda
/// backend'in (zaten Türkçe) mesajı gösterilir.
String supplierErrorText(Object error) {
  if (error is ApiException) {
    return error.isForbidden ? 'Bu işlem için yetkin yok.' : error.message;
  }
  return 'Beklenmeyen bir hata oluştu.';
}

bool isForbiddenError(Object? error) => error is ApiException && error.isForbidden;

/// "Yalnızca görüntüleyebilirsin" kutusu -- tüm Yönetim ekranlarıyla aynı
/// ortak görünüm ([ReadOnlyNotice]).
class SupplierReadOnlyNotice extends StatelessWidget {
  const SupplierReadOnlyNotice({super.key, this.text = kSuppliersReadOnlyText});

  final String text;

  @override
  Widget build(BuildContext context) => ReadOnlyNotice(text);
}

/// İzin yok (okuma izni hiç yok ya da sunucu 403 döndü) -- ekran ÇÖKMEZ,
/// ortak [NoAccessView] gösterilir. Kaydırılabilir: listenin
/// pull-to-refresh'i bu durumda da çalışır.
class SupplierNoAccessView extends StatelessWidget {
  const SupplierNoAccessView({super.key, this.message = kSuppliersNoAccessText});

  final String message;

  @override
  Widget build(BuildContext context) => NoAccessView(message: message, scrollable: true);
}

/// Detay satırı -- ortak `AppDataRow` düzeni (değer sağa yaslı); uzun
/// unvan/adres/not değerleri kesilmez, etiketin altına tam yazılır. Boş
/// değer soluk "—" (alanın var olduğu ama doldurulmadığı anlaşılsın).
/// [trailing] verilirse değer yerine o bileşen (ör. IBAN rozeti) çizilir.
class SupplierInfoRow extends StatelessWidget {
  const SupplierInfoRow({super.key, required this.label, this.value, this.trailing});

  final String label;
  final String? value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = value ?? '';
    return AppDataRow(
      label: label,
      value: text.isEmpty ? '—' : text,
      valueColor: text.isEmpty ? AppColors.textMuted : null,
      multiline: true,
      trailing: trailing,
    );
  }
}

/// Başlıklı bilgi kartı (detay ekranının bölümleri).
class SupplierInfoCard extends StatelessWidget {
  const SupplierInfoCard({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AppTypography.sectionTitle),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ],
    );
  }
}

/// Liste yüklenirken kart iskeleti ("0 tedarikçi" yanıltıcı olurdu).
class SupplierListSkeleton extends StatelessWidget {
  const SupplierListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        for (var i = 0; i < 6; i++) ...[
          const SkeletonBox(height: 76, radius: AppRadius.card),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

/// Arşivle/Etkinleştir onayı -- web `useConfirmDialog` ile aynı başlık,
/// metin ve buton etiketleri. Arşivleme yıkıcı tonda (kırmızı) gösterilir.
Future<bool> confirmSupplierAction(
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
