import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/async_state_view.dart';

final _packageInfoProvider = FutureProvider.autoDispose<PackageInfo>((ref) => PackageInfo.fromPlatform());

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
            const SizedBox(height: 12),
            const Center(
              child: CircleAvatar(
                radius: 32,
                backgroundColor: AppColors.navDark,
                child: Icon(Icons.business_outlined, color: AppColors.gold, size: 32),
              ),
            ),
            const SizedBox(height: 12),
            const Center(
              child: Text('ArvenYapı', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Sürüm ${info.version} (${info.buildNumber})',
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'ArvenYapı, saha ekipleri için proje, teklif ve metraj yönetimi uygulamasıdır.',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
