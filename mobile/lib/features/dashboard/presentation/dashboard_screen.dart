import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../notifications/data/notifications_providers.dart';
import '../../offers/data/offers_providers.dart';
import '../../projects/data/projects_providers.dart';

/// Backend'de özel bir dashboard/özet ucu YOK (bkz. MOBILE_BACKEND_GAPS.md).
/// Bu ekran yalnızca zaten var olan liste uçlarından (projeler, teklifler)
/// minimum sayıda istekle güvenli bir özet kurar; hiçbir toplam mobilde
/// yeniden hesaplanmaz (backend'in kendi `total`/`grand_total` alanları
/// kullanılır).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeProjects = ref.watch(projectsListProvider('active'));
    final openOffers = ref.watch(offersListProvider(''));
    final unreadCount = ref.watch(unreadNotificationCountProvider).maybeWhen(data: (c) => c, orElse: () => 0);

    return Scaffold(
      appBar: buildAppBar('Ana Sayfa', actions: [
        IconButton(
          icon: Badge(
            label: Text('$unreadCount'),
            isLabelVisible: unreadCount > 0,
            child: const Icon(Icons.notifications_outlined),
          ),
          tooltip: 'Bildirimler',
          onPressed: () => context.push('/diger/bildirimler'),
        ),
      ]),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(projectsListProvider('active'));
          ref.invalidate(offersListProvider(''));
        },
        child: ListView(
          padding: kScreenPadding,
          children: [
            Row(
              children: [
                Expanded(
                  child: _SummaryCard(
                    label: 'Aktif Proje',
                    value: activeProjects.maybeWhen(
                      data: (r) => '${r.total}',
                      orElse: () => '—',
                    ),
                    icon: Icons.business_outlined,
                    onTap: () => context.go('/projeler'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryCard(
                    label: 'Açık Teklif',
                    value: openOffers.maybeWhen(
                      data: (r) => '${r.total}',
                      orElse: () => '—',
                    ),
                    icon: Icons.description_outlined,
                    onTap: () => context.go('/teklifler'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text('Son Projeler', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            AsyncStateView(
              value: activeProjects,
              onRetry: () async => ref.invalidate(projectsListProvider('active')),
              isEmpty: (r) => r.projects.isEmpty,
              emptyBuilder: (_) => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: EmptyStateView(message: 'Aktif proje yok.'),
              ),
              data: (context, r) => Column(
                children: r.projects
                    .take(5)
                    .map((p) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(p.projectNo),
                            trailing: Text(Formatters.money(p.contractAmount, currency: p.currency)),
                            onTap: () => context.push('/projeler/${p.id}'),
                          ),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.label, required this.value, required this.icon, required this.onTap});

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppColors.gold),
              const SizedBox(height: 10),
              Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
            ],
          ),
        ),
      ),
    );
  }
}
