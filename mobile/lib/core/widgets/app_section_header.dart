import 'package:flutter/material.dart';

import '../theme/app_typography.dart';

/// Bir bölümün başlığı + isteğe bağlı sağdaki aksiyon (ör. "Ekle" butonu).
/// Ekranlarda tekrarlanan `Row(mainAxisAlignment: spaceBetween, ...)`
/// kalıbının yerini alır.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(title, style: AppTypography.sectionTitle)),
          ?trailing,
        ],
      ),
    );
  }
}
