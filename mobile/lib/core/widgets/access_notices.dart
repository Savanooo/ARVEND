import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Yetki durumlarının TEK görünümü. Diğer > Yönetim altındaki ekranların
/// (Ürünler, Personel, Kullanıcılar, Roller, Tedarikçiler, Maliyet Kodları,
/// Metraj Reçeteleri, E-posta Ayarları, Proje Düzenle) hepsi bu iki
/// bileşeni kullanır; art arda açılan ekranlar aynı dili konuşsun diye her
/// modül kendi kutusunu/kilidini ÇİZMEZ.
///
/// Metinlerde izin adı düz çift tırnakla yazılır: `"Ürün kataloğunu
/// düzenleme"` (web ile aynı).

/// Ekranı hiç göremeyen kişi (izin yok ya da sunucu 403 döndü): ortada
/// yuvarlak kilit + başlık + ne gerektiğini söyleyen metin.
///
/// [scrollable]: pull-to-refresh olan gövdelerde (RefreshIndicator altında)
/// true verilir -- içerik yine ortalanır ama aşağı çekme çalışır.
class NoAccessView extends StatelessWidget {
  const NoAccessView({super.key, required this.message, this.title = 'Yetkin yok', this.scrollable = false});

  final String title;
  final String message;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: AppColors.textMuted.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: const Icon(Icons.lock_outline, color: AppColors.textMuted, size: 26),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(title, style: AppTypography.sectionTitle, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.xs),
          Text(message, style: AppTypography.metadata, textAlign: TextAlign.center),
        ],
      ),
    );
    if (!scrollable) return Center(child: content);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight.isFinite ? constraints.maxHeight : 0),
          child: Center(child: content),
        ),
      ),
    );
  }
}

/// "Yalnızca görüntüleyebilirsin" kutusu -- ekranı görebilen ama
/// değiştiremeyen kişiye liste/detay/form üstünde, düzenleme düğmelerinin
/// neden olmadığını söyler. Durum/uyarı değil bilgi olduğu için ne gold
/// (marka vurgusu) ne mavi: gri zemin + kilit ikonu.
class ReadOnlyNotice extends StatelessWidget {
  const ReadOnlyNotice(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.textMuted.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.textMuted.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(text, style: AppTypography.helper.copyWith(color: AppColors.textMuted, height: 1.35)),
          ),
        ],
      ),
    );
  }
}
