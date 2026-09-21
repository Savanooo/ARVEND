import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';

final _packageInfoProvider = FutureProvider.autoDispose<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
);

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final infoAsync = ref.watch(_packageInfoProvider);

    return Scaffold(
      appBar: buildAppBar('Hakkında'),
      body: AsyncStateView(
        value: infoAsync,
        data: (context, info) => ListView(
          padding: kScreenPadding,
          children: [
            const SizedBox(height: AppSpacing.md),
            const Center(
              child: CircleAvatar(
                radius: 32,
                backgroundColor: AppColors.navDark,
                child: Icon(
                  Icons.business_outlined,
                  color: AppColors.gold,
                  size: 32,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            const Center(
              child: Text('ArvenYapı', style: AppTypography.pageTitle),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Sürüm ${info.version} (${info.buildNumber})',
                style: AppTypography.metadata,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            const AppCard(
              child: Text(
                'ArvenYapı, saha ekipleri için proje, teklif ve metraj yönetimi uygulamasıdır.',
                style: AppTypography.body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
