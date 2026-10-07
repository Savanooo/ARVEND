import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/money_text.dart';
import '../data/budget_providers.dart';
import '../domain/budget.dart';
import 'widgets/budget_ui.dart';

/// Gerçekleşen (web `ActualCostTab`): Finans > Masraflar kayıtlarının
/// maliyet koduna göre kırılımı -- AYRI bir gerçekleşen-maliyet kaydı
/// DEĞİLDİR. Masraflar `projects.finance.read` ister; maliyet kodu adları
/// katalog okunabiliyorsa gösterilir (değilse yalnızca kimlik yok sayılır).
class ActualCostScreen extends ConsumerWidget {
  const ActualCostScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const title = Text('Gerçekleşen');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (isAuthPending(auth)) return AppPageScaffold(title: title, body: const LoadingState());
    if (!user.can(kFinanceReadPermission)) {
      return const AppPageScaffold(
        title: title,
        body: BudgetNoAccessView(message: kActualNoAccessText),
      );
    }
    final expensesAsync = ref.watch(budgetActualExpensesProvider(projectId));
    final codes = user.can(kCostCodesReadPermission)
        ? (ref.watch(budgetCostCodesProvider).valueOrNull ?? const <OrgCostCode>[])
        : const <OrgCostCode>[];
    final codeById = {for (final c in codes) c.id: c};

    Future<void> refresh() async {
      ref.invalidate(budgetActualExpensesProvider(projectId));
      try {
        await ref.read(budgetActualExpensesProvider(projectId).future);
      } catch (_) {
        // Hata gövdede gösterilir.
      }
    }

    return AppPageScaffold(
      title: title,
      body: expensesAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isBudgetForbidden(e)
            ? const BudgetNoAccessView(message: kActualNoAccessText)
            : ErrorState(error: e, onRetry: refresh),
        data: (expenses) {
          // Gerçekleşen yalnızca ONAYLI masraflardan (backend migration 0060);
          // onay bekleyenler yalnızca not olarak sayılır.
          final live = expenses.where((e) => e.countsAsActual).toList();
          final mapped = live.where((e) => e.costCodeId != null).toList();
          final unmapped = live.length - mapped.length;
          final pending = expenses.where((e) => e.isPending).length;
          return RefreshIndicator(
            onRefresh: refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
              children: [
                const BudgetInfoNote(
                  'Bu tablo, Finans > Masraflar bölümünde girilen kayıtların maliyet koduna göre kırılımıdır — ayrı bir '
                  'gerçekleşen-maliyet kaydı değildir (tek gerçek kaynak, mükerrer kayıt yok).',
                ),
                const SizedBox(height: AppSpacing.lg),
                if (pending > 0) ...[
                  BudgetInfoNote(
                    '$pending masraf onay bekliyor — onaylanınca gerçekleşen maliyete girer.',
                    icon: Icons.hourglass_empty,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
                if (live.isEmpty)
                  const EmptyStateView(
                    message:
                        'Henüz gider kaydı yok. Gerçekleşen maliyet, Finans > Masraflar bölümünde girilip '
                        'onaylanan kayıtlardan gelir.',
                    icon: Icons.receipt_long_outlined,
                  )
                else ...[
                  if (mapped.isNotEmpty) ...[
                    Text('${mapped.length} masraf maliyet koduna eşlenmiş', style: AppTypography.metadata),
                    const SizedBox(height: AppSpacing.sm),
                    for (final group in _groupByCostCode(mapped, codeById)) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
                        child: Text(
                          group.label,
                          style: AppTypography.cardTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      AppCard(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Column(
                          children: [
                            for (var i = 0; i < group.expenses.length; i++) ...[
                              if (i > 0) const Divider(height: 1),
                              _ExpenseRow(expense: group.expenses[i]),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                  if (unmapped > 0) ...[
                    const SizedBox(height: AppSpacing.sm),
                    BudgetInfoNote(
                      '$unmapped masraf kaydı henüz bir maliyet koduna eşlenmemiş — Finans > Masraflar bölümünden '
                      '(web) düzenleyerek maliyet kodu ekleyebilirsin.',
                      icon: Icons.link_off,
                    ),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Maliyet kodu grubu -- sıra kod adına göre; masrafların kendi sırası
/// (backend: tarih azalan) korunur. Toplam HESAPLANMAZ (tek kaynak backend).
List<({String label, List<ActualExpense> expenses})> _groupByCostCode(
  List<ActualExpense> mapped,
  Map<String, OrgCostCode> codeById,
) {
  final groups = <String, List<ActualExpense>>{};
  for (final e in mapped) {
    groups.putIfAbsent(e.costCodeId!, () => []).add(e);
  }
  String label(String id) {
    final c = codeById[id];
    return c == null ? 'Maliyet kodu' : '${c.code} — ${c.name}';
  }

  final ids = groups.keys.toList()..sort((a, b) => label(a).compareTo(label(b)));
  return [for (final id in ids) (label: label(id), expenses: groups[id]!)];
}

class _ExpenseRow extends StatelessWidget {
  const _ExpenseRow({required this.expense});

  final ActualExpense expense;

  @override
  Widget build(BuildContext context) {
    final e = expense;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.description.isEmpty ? '—' : e.description,
                  style: AppTypography.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(Formatters.date(e.expenseDate), style: AppTypography.helper),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          MoneyText(
            e.amount,
            currency: e.currency,
            style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
