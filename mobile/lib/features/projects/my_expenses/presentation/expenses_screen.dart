import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_filter_bar.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../domain/expense_actions.dart';
import '../../domain/project.dart';
import '../../finance_ledger/presentation/ledger_entry_sheet.dart';
import '../../finance_ledger/presentation/ledger_ui.dart' show isLedgerLocked;
import '../data/my_expenses_repository.dart';
import '../domain/my_expense.dart';
import 'add_expense_flow.dart';
import 'my_expenses_screen.dart' show kMyExpensesNoAccessText;

/// "Masraflar" (Diğer > İş Araçları, backend migration 0068): projeli ve
/// genel (projesiz) masraflar tek listede. Finans okuma izni olan kişi
/// herkesin masrafını toplamlarla görür ve onay bekleyenlere buradan karar
/// verir; olmayan yalnızca kendi girdiklerini görür. "+" genel masraf ya da
/// bir projeye masraf girer.
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key, this.initialStatus = ''});

  /// `?durum=pending` -- bildirimden/ana sayfadan "onay bekleyenler".
  final String initialStatus;

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

const _statusChips = <(String, String)>[
  ('', 'Tümü'),
  ('pending', 'Onay bekliyor'),
  ('approved', 'Onaylandı'),
  ('rejected', 'Reddedildi'),
];

const _kindChips = <(String, String)>[
  ('', 'Hepsi'),
  ('general', 'Genel'),
  ('project', 'Projeli'),
];

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  late String _status = _statusChips.any((c) => c.$1 == widget.initialStatus) ? widget.initialStatus : '';
  String _kind = '';

  ExpensesQuery get _query => (kind: _kind, status: _status);

  Future<void> _refresh() async {
    ref.invalidate(allExpensesProvider(_query));
    await ref.read(allExpensesProvider(_query).future).catchError(
          (_) => const ExpensesPage(rows: [], canSeeAll: false, totals: [], truncated: false),
        );
  }

  void _openDetail(ListedExpense item) {
    final user = ref.read(authControllerProvider).valueOrNull;
    final row = item.row;
    final open = row.isGeneral || !isLedgerLocked(row.projectStatus);
    final actions = expenseActionsFor(user, row.expense, open: open);
    showExpenseDetailSheet(
      context,
      projectId: row.projectId,
      expense: row.expense,
      currency: row.expense.currency,
      canVoid: actions.canVoid,
      canDecide: actions.canDecide,
      canEdit: actions.canEdit,
      canWithdraw: actions.canWithdraw,
      ownDecisionBlocked: actions.ownDecisionBlocked,
      projectLabel: row.projectLabel,
    );
  }

  /// "+": genel masraf mı, bir projeye mi (bkz. startAddExpense).
  Future<void> _addExpense() => startAddExpense(context);

  @override
  Widget build(BuildContext context) {
    const title = Text('Masraflar');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (auth.isLoading && user == null) return const AppPageScaffold(title: title, body: LoadingState());
    if (!user.can(kExpenseCreatePermission)) {
      return const AppPageScaffold(
        title: title,
        body: Padding(padding: EdgeInsets.all(AppSpacing.lg), child: ReadOnlyNotice(kMyExpensesNoAccessText)),
      );
    }
    final async = ref.watch(allExpensesProvider(_query));

    return AppPageScaffold(
      title: title,
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('masraf-ekle'),
        onPressed: _addExpense,
        icon: const Icon(Icons.add),
        label: const Text('Masraf Ekle'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: AppFilterBar(
              chips: [
                for (final c in _statusChips)
                  AppFilterChipData(label: c.$2, selected: _status == c.$1, onTap: () => setState(() => _status = c.$1)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xs),
            child: AppFilterBar(
              chips: [
                for (final c in _kindChips)
                  AppFilterChipData(label: c.$2, selected: _kind == c.$1, onTap: () => setState(() => _kind = c.$1)),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: AsyncStateView<ExpensesPage>(
                value: async,
                onRetry: _refresh,
                data: (context, page) => ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 96),
                  children: [
                    if (page.canSeeAll && page.totals.isNotEmpty) _TotalsCard(totals: page.totals),
                    if (page.rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xl),
                        child: EmptyStateView(
                          message: _status.isEmpty && _kind.isEmpty
                              ? 'Henüz masraf yok. Sağ alttaki "Masraf Ekle" ile genel ya da projeye masraf gir.'
                              : 'Bu süzgeçte masraf yok.',
                          icon: Icons.receipt_long_outlined,
                        ),
                      )
                    else
                      for (final item in page.rows)
                        _ExpenseCard(
                          key: ValueKey('masraf-${item.expense.id}'),
                          item: item,
                          showCreator: page.canSeeAll,
                          onTap: () => _openDetail(item),
                        ),
                    if (page.truncated)
                      const Padding(
                        padding: EdgeInsets.only(top: AppSpacing.sm),
                        child: Text(
                          'Yalnızca en yeni masraflar gösteriliyor; daha eskileri için süzgeç kullan.',
                          style: AppTypography.helper,
                        ),
                      ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      page.canSeeAll
                          ? 'Toplamlar onaylı ve onay bekleyen masrafları içerir; reddedilen ve iptal edilenler '
                                'sayılmaz. Genel masraflar proje kârına girmez.'
                          : 'Girdiğin masraf yönetici onaylayınca kesinleşir. Reddedilen masrafı nedenine bakıp '
                                'düzeltebilir ya da geri çekebilirsin.',
                      style: AppTypography.helper,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals});

  final List<ExpenseTotals> totals;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const ValueKey('masraf-toplamlar'),
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final t in totals)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Onaylı: ${Formatters.money(t.approved, currency: t.currency)}',
                      style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (t.pending > 0)
                    Text(
                      'Bekleyen: ${Formatters.money(t.pending, currency: t.currency)}',
                      style: AppTypography.metadata.copyWith(color: AppColors.warning),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Tek masraf kartı: kategori + durum çipi, proje (ya da "Genel masraf") ·
/// tarih · açıklama · giren, tutar; reddedilende ret nedeni, iptalde soluk.
class _ExpenseCard extends StatelessWidget {
  const _ExpenseCard({super.key, required this.item, required this.showCreator, required this.onTap});

  final ListedExpense item;
  final bool showCreator;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = item.expense;
    final Widget badge = e.isVoided
        ? StatusBadge(label: e.isWithdrawn ? 'Geri çekildi' : 'İptal edildi', tone: StatusTone.muted)
        : StatusRegistry.build(e.approvalStatus, StatusRegistry.expenseApproval);
    final details = [
      item.row.projectLabel,
      Formatters.date(e.expenseDate),
      if (e.description.isNotEmpty) e.description,
      if (showCreator && item.createdByName.isNotEmpty) item.createdByName,
    ].where((p) => p.isNotEmpty).join(' · ');
    return Opacity(
      opacity: e.isVoided ? 0.6 : 1,
      child: AppCard(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.all(AppSpacing.md),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          expenseCategories[e.category] ?? e.category,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.cardTitle,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      badge,
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  Formatters.money(e.amount, currency: e.currency.isEmpty ? 'TRY' : e.currency),
                  style: AppTypography.body.copyWith(
                    fontWeight: FontWeight.w700,
                    decoration: e.isVoided ? TextDecoration.lineThrough : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(details, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.metadata),
            if (e.isRejected && !e.isVoided && e.decisionNote.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Red nedeni: ${e.decisionNote}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.metadata.copyWith(color: AppColors.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
