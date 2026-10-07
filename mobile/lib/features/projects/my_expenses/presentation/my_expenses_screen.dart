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
import '../../../dashboard/domain/dashboard_registry.dart' show QuickActionKey;
import '../../../dashboard/presentation/widgets/quick_actions_row.dart' show runQuickAction;
import '../../domain/expense_actions.dart';
import '../../domain/project.dart';
import '../../finance_ledger/presentation/ledger_entry_sheet.dart';
import '../../finance_ledger/presentation/ledger_ui.dart' show isLedgerLocked;
import '../data/my_expenses_repository.dart';
import '../domain/my_expense.dart';

/// Masraf girmeyi açan izin yokken (firma rolünden kaldırdıysa).
const kMyExpensesNoAccessText =
    'Masraf girme yetkin yok. Yöneticinden rolüne "Projeye masraf girme" iznini eklemesini isteyebilirsin.';

/// "Masraflarım" (Diğer > İş Araçları, Ana Sayfa hızlı işlemi; backend
/// migration 0066): kişinin KENDİ girdiği masraflar, projeler arası, en yeni
/// önce -- durum çipi (Onay bekliyor / Onaylandı / Reddedildi + ret nedeni,
/// Geri çekildi). Satıra dokununca ayrıntı; kendi bekleyen/reddedilen
/// masrafında Düzenle / Geri Çek. Finans okuma izni gerekmez: sunucu
/// yalnızca kişinin kendi kayıtlarını döndürür, toplam göstermeyiz.
///
/// [projectId] (`?proje=`): proje ekranından açılınca o projeyle süzülür
/// ("Tüm projeler" kaldırır). [initialExpenseId] (`?masraf=`): karar
/// bildiriminden gelince o masrafın ayrıntısı bir kez açılır.
class MyExpensesScreen extends ConsumerStatefulWidget {
  const MyExpensesScreen({super.key, this.projectId, this.initialExpenseId});

  final String? projectId;
  final String? initialExpenseId;

  @override
  ConsumerState<MyExpensesScreen> createState() => _MyExpensesScreenState();
}

class _MyExpensesScreenState extends ConsumerState<MyExpensesScreen> {
  MyExpenseFilter _filter = MyExpenseFilter.all;
  late String? _projectId = _nonEmpty(widget.projectId);
  ProviderSubscription<AsyncValue<List<MyExpense>>>? _initialSub;
  bool _initialHandled = false;

  static String? _nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;

  @override
  void initState() {
    super.initState();
    final target = _nonEmpty(widget.initialExpenseId);
    if (target != null) {
      // Liste ilk kez geldiğinde (build dışında, bir kez) ayrıntı açılır.
      _initialSub = ref.listenManual<AsyncValue<List<MyExpense>>>(myExpensesProvider(_projectId), (_, next) {
        final rows = next.valueOrNull;
        if (rows == null || _initialHandled) return;
        _initialHandled = true;
        for (final row in rows) {
          if (row.expense.id == target) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _openDetail(row);
            });
            return;
          }
        }
      }, fireImmediately: true);
    }
  }

  @override
  void dispose() {
    _initialSub?.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(myExpensesProvider(_projectId));
    await ref.read(myExpensesProvider(_projectId).future).catchError((_) => const <MyExpense>[]);
  }

  void _openDetail(MyExpense row) {
    final user = ref.read(authControllerProvider).valueOrNull;
    final actions = expenseActionsFor(user, row.expense, open: !isLedgerLocked(row.projectStatus));
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

  @override
  Widget build(BuildContext context) {
    const title = Text('Masraflarım');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (auth.isLoading && user == null) return const AppPageScaffold(title: title, body: LoadingState());
    if (!user.can(kExpenseCreatePermission)) {
      return const AppPageScaffold(
        title: title,
        body: Padding(padding: EdgeInsets.all(AppSpacing.lg), child: ReadOnlyNotice(kMyExpensesNoAccessText)),
      );
    }

    final async = ref.watch(myExpensesProvider(_projectId));
    final rows = async.valueOrNull ?? const <MyExpense>[];
    int count(MyExpenseFilter f) => rows.where((r) => f.matches(r.expense)).length;
    String chipLabel(MyExpenseFilter f) => async.hasValue ? '${f.label} (${count(f)})' : f.label;

    return AppPageScaffold(
      title: title,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Masraf Ekle',
        onPressed: () => runQuickAction(context, QuickActionKey.expense),
        child: const Icon(Icons.add),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_projectId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
              child: Row(
                children: [
                  const Icon(Icons.apartment_outlined, size: 18, color: AppColors.textMuted),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      rows.isEmpty ? 'Bu projedeki masrafların' : rows.first.projectLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.metadata,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      // Bildirimden açılış bitti; eski süzgecin aboneliği kalmasın.
                      _initialSub?.close();
                      _initialSub = null;
                      _projectId = null;
                    }),
                    child: const Text('Tüm projeler'),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
            child: AppFilterBar(
              chips: [
                for (final f in MyExpenseFilter.values)
                  AppFilterChipData(
                    label: chipLabel(f),
                    selected: _filter == f,
                    onTap: () => setState(() => _filter = f),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: AsyncStateView<List<MyExpense>>(
                value: async,
                onRetry: _refresh,
                data: (context, all) {
                  final visible = all.where((r) => _filter.matches(r.expense)).toList();
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 96),
                    children: [
                      if (visible.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xl),
                          child: EmptyStateView(
                            message: all.isEmpty
                                ? 'Henüz masraf girmedin. Sağ alttaki + ile masrafını gir; onaylanınca projenin '
                                      'maliyetine işlenir.'
                                : 'Bu durumda masrafın yok.',
                            icon: Icons.receipt_long_outlined,
                          ),
                        )
                      else
                        for (final row in visible)
                          _MyExpenseCard(key: ValueKey('masrafim-${row.expense.id}'), row: row, onTap: () => _openDetail(row)),
                      const SizedBox(height: AppSpacing.md),
                      const Text(
                        'Girdiğin masraf yönetici onaylayınca projenin maliyetine işlenir. Reddedilen masrafı nedenine '
                        'bakıp düzeltebilir ya da geri çekebilirsin.',
                        style: AppTypography.helper,
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

/// Tek masraf kartı: kategori + durum çipi, proje · tarih · açıklama, tutar;
/// reddedilende kırmızı ret nedeni, geri çekilen/iptal edilende soluk satır.
class _MyExpenseCard extends StatelessWidget {
  const _MyExpenseCard({super.key, required this.row, required this.onTap});

  final MyExpense row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = row.expense;
    final Widget badge = e.isVoided
        ? StatusBadge(label: e.isWithdrawn ? 'Geri çekildi' : 'İptal edildi', tone: StatusTone.muted)
        : StatusRegistry.build(e.approvalStatus, StatusRegistry.expenseApproval);
    final details = [
      row.projectLabel,
      Formatters.date(e.expenseDate),
      if (e.description.isNotEmpty) e.description,
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
                // Başlık yalnızca sığmazsa kısalır; çip hemen yanında durur.
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
