import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Geri alınamaz iptal/fesih aksiyonu (Sözleşmeyi İptal Et/Feshet, Ek İşi
/// İptal Et, Kalemi İptal Et, Faturayı İptal Et, Aşamayı İptal Et,
/// Taahhüdü İptal Et, masraf/tahsilat İptal Et): tam genişlikte, kırmızı
/// yazı + kenarlıkla, aksiyon çubuğunun ALTINDA ayrı durur -- "Düzenle" ya
/// da "Linki Kopyala" ile aynı ağırlıkta görünmesin (web `variant="danger"`).
/// Proje alt modüllerinin hepsi (detay ekranları ve alt sayfalar) bunu
/// kullanır; onayı/gerekçeyi çağıran sorar.
class DestructiveActionButton extends StatelessWidget {
  const DestructiveActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.cancel_outlined,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final enabled = !loading && onPressed != null;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.danger,
        side: BorderSide(color: enabled ? AppColors.danger.withValues(alpha: 0.6) : AppColors.border),
      ),
      onPressed: loading ? null : onPressed,
      icon: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.danger),
            )
          : Icon(icon, size: 18),
      label: Text(label),
    );
  }
}
