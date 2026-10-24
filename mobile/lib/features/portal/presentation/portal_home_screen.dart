import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/portal_repository.dart';
import '../domain/portal.dart';

/// Taşeron Paneli ana ekranı (backend GET /portal/overview): taşeron
/// firmanın izin verdiği projelerdeki kendi işlerini, kalan alacağını ve
/// ödemelerini görür. Firma ekranlarının hiçbiri bu hesaba açılmaz.
class PortalHomeScreen extends ConsumerWidget {
  const PortalHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final async = ref.watch(portalOverviewProvider);

    Future<void> refresh() async {
      ref.invalidate(portalOverviewProvider);
      try {
        await ref.read(portalOverviewProvider.future);
      } catch (_) {
        // Hata ekranda gösterilir (AsyncStateView).
      }
    }

    final name = async.valueOrNull?.supplierName ?? '';
    return AppPageScaffold(
      automaticallyImplyLeading: false,
      title: Text(name.isEmpty ? 'Taşeron Paneli' : name),
      actions: [
        IconButton(
          key: const ValueKey('portal-profil'),
          tooltip: 'Profil',
          icon: const Icon(Icons.person_outline),
          onPressed: () => context.push('/taseron/profil'),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: refresh,
        child: AsyncStateView<PortalOverview>(
          value: async,
          onRetry: refresh,
          data: (context, o) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xl),
            children: [
              if (user != null) ...[
                Text('Merhaba, ${user.fullName}', style: AppTypography.pageTitle),
                if (user.organizationName.isNotEmpty)
                  Text('${user.organizationName} ile işleriniz', style: AppTypography.metadata),
                const SizedBox(height: AppSpacing.lg),
              ],
              if (o.projects.isEmpty)
                AppCard(
                  key: const ValueKey('portal-izin-yok'),
                  child: Text(
                    '${user?.organizationName.isNotEmpty == true ? user!.organizationName : 'Firma'} '
                    'size henüz bir proje açmadı. Proje izni verilince işleriniz ve ödemeleriniz burada görünür.',
                    style: AppTypography.body,
                  ),
                ),
              for (final t in o.totals) ...[
                _TotalsCard(totals: t),
                const SizedBox(height: AppSpacing.md),
              ],
              if (o.engagements.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                const AppSectionHeader(title: 'İşlerim'),
                const SizedBox(height: AppSpacing.sm),
                for (final group in _byProject(o.engagements).entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
                    child: Text(group.key, style: AppTypography.cardTitle),
                  ),
                  for (final e in group.value) _EngagementCard(engagement: e),
                ],
              ],
              if (o.payments.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                const AppSectionHeader(title: 'Ödemeler'),
                const SizedBox(height: AppSpacing.sm),
                for (final p in o.payments)
                  AppListCard(
                    key: ValueKey('portal-odeme-${p.id}'),
                    title: Formatters.money(p.amount, currency: p.currency),
                    subtitle: [
                      Formatters.date(p.paidDate),
                      p.projectLabel,
                      if (p.isAdvance) 'Avans',
                      if (p.description.isNotEmpty) p.description,
                    ].join(' · '),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Proje etiketine göre gruplanmış işler (sıra sunucunun sırası).
  Map<String, List<PortalEngagement>> _byProject(List<PortalEngagement> list) {
    final out = <String, List<PortalEngagement>>{};
    for (final e in list) {
      out.putIfAbsent(e.projectLabel, () => []).add(e);
    }
    return out;
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals});
  final PortalTotals totals;

  @override
  Widget build(BuildContext context) {
    final t = totals;
    final cur = t.currency;
    return AppCard(
      key: ValueKey('portal-toplam-$cur'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Kalan alacağınız', style: AppTypography.metadata),
          const SizedBox(height: 2),
          Text(
            Formatters.money(t.remaining, currency: cur),
            style: AppTypography.pageTitle.copyWith(color: AppColors.gold),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppDataRow(label: 'Toplam iş bedeli', value: Formatters.money(t.contractAmount, currency: cur)),
          AppDataRow(label: 'Ödenen', value: Formatters.money(t.paid, currency: cur)),
          if (t.payable > 0)
            AppDataRow(label: 'Ödenecek (onaylı hakediş)', value: Formatters.money(t.payable, currency: cur)),
          if (t.retention > 0)
            AppDataRow(label: 'Teminatta tutulan', value: Formatters.money(t.retention, currency: cur)),
        ],
      ),
    );
  }
}

class _EngagementCard extends StatelessWidget {
  const _EngagementCard({required this.engagement});
  final PortalEngagement engagement;

  @override
  Widget build(BuildContext context) {
    final e = engagement;
    final cur = e.currency;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        key: ValueKey('portal-is-${e.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.title.isEmpty ? (e.isContract ? 'Sözleşme' : 'İş') : e.title, style: AppTypography.body),
            const SizedBox(height: AppSpacing.xs),
            AppDataRow(label: e.isContract ? 'Sözleşme bedeli' : 'İş bedeli', value: Formatters.money(e.contractAmount, currency: cur)),
            if (e.certified != null)
              AppDataRow(label: 'Onaylı hakediş', value: Formatters.money(e.certified!, currency: cur)),
            AppDataRow(label: 'Ödenen', value: Formatters.money(e.paid, currency: cur)),
            if (e.payable > 0) AppDataRow(label: 'Ödenecek', value: Formatters.money(e.payable, currency: cur)),
            if (e.retention > 0) AppDataRow(label: 'Teminatta', value: Formatters.money(e.retention, currency: cur)),
            if (e.advanceOpen > 0) AppDataRow(label: 'Açık avans', value: Formatters.money(e.advanceOpen, currency: cur)),
            if (e.pendingClaims > 0)
              AppDataRow(label: 'Onay bekleyen hakediş', value: Formatters.money(e.pendingClaims, currency: cur)),
            AppDataRow(label: 'Kalan', value: Formatters.money(e.remaining, currency: cur), emphasize: true),
          ],
        ),
      ),
    );
  }
}
