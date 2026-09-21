import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import 'app_buttons.dart';

/// Tek bir yaşam döngüsü aksiyonu (ör. Gönder/Onayla/Reddet/İptal Et).
/// Hangi aksiyonların hangi durumda/izinle göründüğünü HER EKRAN KENDİSİ
/// belirler -- bu yalnızca zaten hesaplanmış bir listeyi tutarlı biçimde
/// dizmekle ilgilidir, iş kuralı İÇERMEZ.
class AppLifecycleAction {
  const AppLifecycleAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  // true olan İLK aksiyon tam genişlikte, birincil (gold) buton olarak
  // ayrılır; geri kalanı ikincil butonlar olarak sarmalanır.
  final bool primary;
  final bool loading;
}

/// Teklif/Talep/RFQ/Sipariş/Taşeron/Hakediş/Ek İş detaylarında tekrarlanan
/// "durum + izne göre değişen aksiyon çubuğu" düzenini tek yerde toplar.
class AppLifecycleActions extends StatelessWidget {
  const AppLifecycleActions({super.key, required this.actions});

  final List<AppLifecycleAction> actions;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();

    final primaryIndex = actions.indexWhere((a) => a.primary);
    final primary = primaryIndex >= 0 ? actions[primaryIndex] : null;
    final secondary = [for (var i = 0; i < actions.length; i++) if (i != primaryIndex) actions[i]];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (primary != null)
          PrimaryButton(
            label: primary.label,
            icon: primary.icon,
            loading: primary.loading,
            onPressed: primary.onPressed,
          ),
        if (primary != null && secondary.isNotEmpty) const SizedBox(height: AppSpacing.sm),
        if (secondary.isNotEmpty)
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final a in secondary)
                SecondaryButton(label: a.label, icon: a.icon, loading: a.loading, onPressed: a.onPressed),
            ],
          ),
      ],
    );
  }
}
