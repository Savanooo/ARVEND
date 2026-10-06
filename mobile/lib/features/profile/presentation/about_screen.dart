import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_shell.dart';
import '../../../core/config/app_config.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/update/update_check_tile.dart';
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
              child: Text('ARVEND Yapı', style: AppTypography.pageTitle),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Sürüm ${info.version} (${info.buildNumber})',
                style: AppTypography.metadata,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            // Yalnızca Android'de görünür (store'a çıkana kadar APK
            // sunucudan güncellenir, bkz. core/update/).
            const UpdateCheckTile(),
            const AppCard(
              child: Text(
                'ARVEND Yapı; proje, teklif, şantiye, görev ve personel yönetimi uygulamasıdır.',
                style: AppTypography.body,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            AppCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Gizlilik Politikası ve KVKK'),
                subtitle: const Text('Verilerin nasıl işlendiği, hesap silme'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => launchUrl(
                  Uri.parse(AppConfig.privacyPolicyUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
