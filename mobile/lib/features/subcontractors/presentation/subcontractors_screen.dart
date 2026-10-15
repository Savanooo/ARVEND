import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/subcontractors_repository.dart';
import '../domain/subcontractor.dart';
import 'subcontractor_card_form_sheet.dart';

/// "Taşeronlar" (Diğer > İş Araçları, backend migration 0069): firmanın
/// taşeron kartları. Finans okuyabilen her kartta ödenen toplamı görür.
/// Karta dokununca taşeronun sayfası (projelerdeki işleri ve bütün
/// ödemeleri) açılır. "Yeni Taşeron" organization.suppliers.manage ister.
class SubcontractorsScreen extends ConsumerStatefulWidget {
  const SubcontractorsScreen({super.key});

  @override
  ConsumerState<SubcontractorsScreen> createState() => _SubcontractorsScreenState();
}

class _SubcontractorsScreenState extends ConsumerState<SubcontractorsScreen> {
  String _query = '';
  bool _archived = false;

  Future<void> _refresh() async {
    ref.invalidate(subcontractorCardsProvider);
    await ref.read(subcontractorCardsProvider.future).catchError(
          (_) => const SubcontractorCardsPage(cards: [], canSeeTotals: false),
        );
  }

  Future<void> _create() async {
    final created = await showSubcontractorCardFormSheet(context);
    if (created != null && mounted) context.push('/diger/taseronlar/${created.id}');
  }

  @override
  Widget build(BuildContext context) {
    const title = Text('Taşeronlar');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (auth.isLoading && user == null) return const AppPageScaffold(title: title, body: LoadingState());
    if (!user.canAccess('organization.suppliers.read')) {
      return const AppPageScaffold(
        title: title,
        body: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: ReadOnlyNotice('Taşeronları görmek için yetkin yok.'),
        ),
      );
    }
    final canCreate = user.canAccess('organization.suppliers.manage');
    final async = ref.watch(subcontractorCardsProvider);
    final q = _query.toLowerCase();

    return AppPageScaffold(
      title: title,
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              key: const ValueKey('taseron-ekle'),
              onPressed: _create,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Yeni Taşeron'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Ad, branş ya da telefon ara',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
            child: AppFilterBar(
              chips: [
                AppFilterChipData(label: 'Aktif', selected: !_archived, onTap: () => setState(() => _archived = false)),
                AppFilterChipData(label: 'Arşiv', selected: _archived, onTap: () => setState(() => _archived = true)),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: AsyncStateView<SubcontractorCardsPage>(
                value: async,
                onRetry: _refresh,
                data: (context, page) {
                  final items = page.cards
                      .where((c) => c.isActive != _archived)
                      .where((c) => q.isEmpty || '${c.name} ${c.subtitle}'.toLowerCase().contains(q))
                      .toList();
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 96),
                    children: [
                      if (items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xl),
                          child: EmptyStateView(
                            message: page.cards.isEmpty
                                ? 'Henüz taşeron yok. "Yeni Taşeron" ile ekle; projelerde listeden seçersin.'
                                : 'Aramaya uyan taşeron yok.',
                            icon: Icons.engineering_outlined,
                          ),
                        )
                      else
                        for (final c in items)
                          _CardRow(
                            key: ValueKey('taseron-${c.id}'),
                            card: c,
                            showTotals: page.canSeeTotals,
                            onTap: () => context.push('/diger/taseronlar/${c.id}'),
                          ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({super.key, required this.card, required this.showTotals, required this.onTap});

  final SubcontractorCard card;
  final bool showTotals;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final paid = card.paidTotals.map((t) => Formatters.money(t.amount, currency: t.currency)).join(' + ');
    final remaining =
        card.remainingTotals.map((t) => Formatters.money(t.amount, currency: t.currency)).join(' + ');
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      child: Row(
        children: [
          const Icon(Icons.engineering_outlined, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(card.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.cardTitle),
                if (card.subtitle.isNotEmpty)
                  Text(card.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.metadata),
              ],
            ),
          ),
          if (showTotals) ...[
            const SizedBox(width: AppSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text('Ödenen', style: AppTypography.helper),
                Text(
                  paid.isEmpty ? Formatters.money(0) : paid,
                  style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
                ),
                if (remaining.isNotEmpty)
                  Text(
                    'Kalan $remaining',
                    key: ValueKey('taseron-kalan-${card.id}'),
                    style: AppTypography.helper.copyWith(color: AppColors.warning, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ],
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}
