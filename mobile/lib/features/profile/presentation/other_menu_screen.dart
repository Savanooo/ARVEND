import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_colors.dart';

class OtherMenuScreen extends StatelessWidget {
  const OtherMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar('Diğer'),
      body: ListView(
        padding: kScreenPadding,
        children: [
          _MenuTile(icon: Icons.straighten_outlined, label: 'Metraj Hesaplama', onTap: () => context.push('/diger/metraj')),
          _MenuTile(icon: Icons.people_outline, label: 'Müşteriler', onTap: () => context.push('/diger/musteriler')),
          _MenuTile(icon: Icons.access_time_outlined, label: 'Mesai', onTap: () => context.push('/diger/mesai')),
          _MenuTile(icon: Icons.person_outline, label: 'Profil', onTap: () => context.push('/diger/profil')),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: AppColors.gold),
        title: Text(label),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
        onTap: onTap,
      ),
    );
  }
}
