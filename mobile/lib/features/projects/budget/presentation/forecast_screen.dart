import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_data_row.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../data/budget_providers.dart';
import '../domain/budget.dart';
import 'sheets/forecast_sheet.dart';
import 'widgets/budget_ui.dart';
import 'widgets/cost_line_widgets.dart';

/// Tahmin (ETC) -- web `ForecastTab`: her bütçe kalemi için Gerçekleşen,
/// ETC (manuel ya da sistem varsayılanı) ve EAC; "Manuel ETC Gir"/
/// "Düzenle" `projects.cost_control.manage` ister. Satırlar maliyet
/// kontrolü kırılımının bütçe kalemine bağlı satırlarıdır (backend'in
/// hesapladığı ETC/EAC aynen gösterilir).
class ForecastScreen extends ConsumerStatefulWidget {
  const ForecastScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends ConsumerState<ForecastScreen> {
  String get _pid => widget.projectId;

  Future<void> _refresh() async {
    ref.invalidate(budgetCostControlProvider(_pid));
    ref.invalidate(budgetForecastsProvider(_pid));
    try {
      await ref.read(budgetCostControlProvider(_pid).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  Future<void> _edit(CostControlLine line, CostForecast? override, String currency) async {
    final saved = await showForecastSheet(
      context,
      projectId: _pid,
      budgetLineId: line.budgetLineId!,
      lineLabel: line.description.isEmpty ? costLineTitle(line) : line.description,
      currency: currency,
      existing: override,
      defaultEtc: line.etc,
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ETC tahmini kaydedildi.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    const title = Text('Tahmin (ETC)');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (isAuthPending(auth)) return AppPageScaffold(title: title, body: const LoadingState());
    if (!user.can(kCostControlReadPermission)) {
      return const AppPageScaffold(
        title: title,
        body: BudgetNoAccessView(message: kCostControlNoAccessText),
      );
    }
    final project = ref.watch(budgetProjectProvider(_pid)).valueOrNull;
    final locked = project != null && isProjectLocked(project.status);
    final hasManage = user.can(kCostControlManagePermission);
    final canManage = hasManage && !locked;
    final ccAsync = ref.watch(budgetCostControlProvider(_pid));
    final forecastsAsync = ref.watch(budgetForecastsProvider(_pid));

    final firstError = ccAsync.error ?? forecastsAsync.error;
    Widget body;
    if (firstError != null) {
      body = isBudgetForbidden(firstError)
          ? const BudgetNoAccessView(message: kCostControlNoAccessText)
          : ErrorState(error: firstError, onRetry: _refresh);
    } else if (!ccAsync.hasValue || !forecastsAsync.hasValue) {
      body = const LoadingState();
    } else {
      final cc = ccAsync.value!;
      final currency = cc.summary.currency;
      final overrides = {for (final f in forecastsAsync.value!) f.budgetLineId: f};
      final lines = [
        for (final l in cc.lines)
          if (l.budgetLineId != null) l,
      ];
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
          children: [
            if (locked) ...[const ReadOnlyNotice(kProjectLockedText), const SizedBox(height: AppSpacing.md)],
            if (!locked && !hasManage) ...[
              const ReadOnlyNotice(kCostControlReadOnlyText),
              const SizedBox(height: AppSpacing.md),
            ],
            const BudgetInfoNote(
              'ETC (Estimate To Complete), her kalem için "bitirmek üzere kalan tahmini maliyet"tir — girilmezse '
              'sistem varsayılan olarak (Revize Bütçe − Gerçekleşen, negatif olamaz) önerir. EAC = Gerçekleşen + ETC.',
            ),
            const SizedBox(height: AppSpacing.lg),
            if (lines.isEmpty)
              const EmptyStateView(message: 'Tahmin girilecek bir bütçe kalemi yok.', icon: Icons.trending_up)
            else
              for (final l in lines)
                _ForecastCard(
                  line: l,
                  forecast: overrides[l.budgetLineId],
                  currency: currency,
                  onEdit: canManage ? () => _edit(l, overrides[l.budgetLineId], currency) : null,
                ),
          ],
        ),
      );
    }
    return AppPageScaffold(title: title, body: body);
  }
}

class _ForecastCard extends StatelessWidget {
  const _ForecastCard({required this.line, required this.forecast, required this.currency, this.onEdit});

  final CostControlLine line;

  /// Kullanıcının girdiği manuel ETC (yoksa sistem varsayılanı kullanılır).
  final CostForecast? forecast;
  final String currency;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final o = forecast;
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  l.description.isEmpty ? costLineTitle(l) : l.description,
                  style: AppTypography.cardTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              o != null
                  // Taahhütlerdeki "Manuel" kaynak etiketiyle aynı (nötr) ton.
                  ? const StatusBadge(label: 'Manuel', tone: StatusTone.muted)
                  : const StatusBadge(label: 'Varsayılan', tone: StatusTone.muted),
            ],
          ),
          Text(costLineTitle(l), style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: AppSpacing.sm),
          AppDataRow(
            label: 'Gerçekleşen',
            value: Formatters.money(l.actualCost, currency: currency),
          ),
          AppDataRow(
            label: 'ETC',
            value: Formatters.money(l.etc, currency: currency),
          ),
          AppDataRow(
            label: 'EAC',
            value: Formatters.money(l.eac, currency: currency),
            emphasize: true,
          ),
          if (o != null && o.note.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text('Not: ${o.note}', style: AppTypography.helper, maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
          if (onEdit != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onEdit,
                icon: Icon(o != null ? Icons.edit_outlined : Icons.add, size: 18),
                label: Text(o != null ? 'Düzenle' : 'Manuel ETC Gir'),
              ),
            )
          else
            const SizedBox(height: AppSpacing.xs),
        ],
      ),
    );
  }
}
