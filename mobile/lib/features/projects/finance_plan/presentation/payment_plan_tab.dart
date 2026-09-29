import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/money_text.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../../core/widgets/viz/progress_bar.dart';
import '../../data/projects_providers.dart';
import '../../domain/project.dart';
import '../data/finance_plan_providers.dart';
import '../domain/finance_dates.dart';
import '../domain/payment_plan.dart';
import '../finance_plan_paths.dart';
import 'widgets/finance_plan_ui.dart';

/// Ödeme Planı -- web `PaymentPlanSection` (projeler/[id]/FinanceSections.tsx)
/// karşılığı. Proje detayının Finans grubunda alt görünüm olarak
/// (`?grup=finans&alt=odeme-plani`) ve tam ekran (`/projeler/:id/odeme-plani`)
/// kullanılır. Okuma `projects.finance.read`, ekleme/düzenleme/iptal
/// `projects.finance.manage` ister (proje detayı ile aynı fail-open
/// `can` deseni; gerçek sınır backend'de, 403 gelirse ekran çökmez).
///
/// Kalem durumu (Bekliyor/Kısmi Tahsil/Tahsil Edildi/Gecikti/İptal) SUNUCUDAN
/// gelir; gecikmiş kalemler kırmızı rozet + vade ipucu ile vurgulanır.
class PaymentPlanTab extends ConsumerWidget {
  const PaymentPlanTab({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (user == null && auth.isLoading) return const LoadingState();
    // İzin yoksa API HİÇ çağrılmaz.
    if (!user.can(kFinancePlanReadPermission)) {
      return const NoAccessView(message: kFinanceNoAccessText, scrollable: true);
    }
    final canManage = user.can(kFinancePlanManagePermission);
    final projectAsync = ref.watch(projectDetailProvider(projectId));
    final planAsync = ref.watch(projectPaymentPlanProvider(projectId));

    Future<void> refresh() async {
      ref.invalidate(projectPaymentPlanProvider(projectId));
      ref.invalidate(projectFinancialSummaryProvider(projectId));
      try {
        await ref.read(projectPaymentPlanProvider(projectId).future);
      } catch (_) {
        // Hata gövdede gösterilir.
      }
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: planAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isFinanceForbidden(e)
            ? const NoAccessView(message: kFinanceNoAccessText, scrollable: true)
            : FinanceScrollableCenter(child: ErrorState(error: e, onRetry: refresh)),
        data: (plan) => projectAsync.when(
          loading: () => const LoadingState(),
          error: (e, _) => isFinanceForbidden(e)
              ? const NoAccessView(message: kFinanceNoAccessText, scrollable: true)
              : FinanceScrollableCenter(
                  child: ErrorState(
                    error: e,
                    onRetry: () async => ref.invalidate(projectDetailProvider(projectId)),
                  ),
                ),
          data: (project) => _PaymentPlanBody(
            projectId: projectId,
            project: project,
            plan: plan,
            canManage: canManage,
          ),
        ),
      ),
    );
  }
}

/// Tam ekran Ödeme Planı (`/projeler/:id/odeme-plani`).
class PaymentPlanScreen extends StatelessWidget {
  const PaymentPlanScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(title: const Text('Ödeme Planı'), body: PaymentPlanTab(projectId: projectId));
  }
}

class _PaymentPlanBody extends ConsumerWidget {
  const _PaymentPlanBody({
    required this.projectId,
    required this.project,
    required this.plan,
    required this.canManage,
  });

  final String projectId;
  final Project project;
  final PaymentPlan plan;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(financePlanTodayProvider);
    final locked = isFinanceLocked(project);
    final canAdd = canManage && !locked;
    // Web ile aynı karşılaştırma: plan toplamı GÜNCEL proje bedeliyle
    // (onaylı ek işler dahil) kıyaslanır. Özet henüz yoksa not gösterilmez.
    final currentContractValue = ref.watch(projectFinancialSummaryProvider(projectId)).valueOrNull?.currentContractValue;

    final addButton = canAdd
        ? TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Kalem Ekle'),
            onPressed: () => context.push(paymentPlanNewPath(projectId)),
          )
        : null;

    final notice = locked
        ? FinanceLockedNotice(project: project)
        : (!canManage ? const ReadOnlyNotice(kPaymentPlanReadOnlyText) : null);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        if (plan.items.isNotEmpty) ...[
          PaymentPlanSummaryCard(
            plan: plan,
            currency: project.currency,
            currentContractValue: currentContractValue,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (notice != null) ...[notice, const SizedBox(height: AppSpacing.md)],
        AppSectionHeader(title: 'Kalemler', trailing: addButton),
        const SizedBox(height: AppSpacing.sm),
        if (plan.items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: EmptyStateView(message: 'Henüz ödeme planı kalemi yok.', icon: Icons.event_note_outlined),
          )
        else
          for (final item in plan.items)
            PaymentPlanItemCard(
              item: item,
              currency: project.currency,
              today: today,
              onTap: () => context.push(paymentPlanItemPath(projectId, item.id)),
            ),
      ],
    );
  }
}

/// Planın özeti: plan toplamı (sunucu), tahsil edilen / kalan (kalem
/// değerleri), durum dağılımı ve web'deki "planlanmamış bakiye" notu.
class PaymentPlanSummaryCard extends StatelessWidget {
  const PaymentPlanSummaryCard({
    super.key,
    required this.plan,
    required this.currency,
    this.currentContractValue,
  });

  final PaymentPlan plan;
  final String currency;
  final double? currentContractValue;

  @override
  Widget build(BuildContext context) {
    final activeCount = plan.activeItems.length;
    final counts = [
      for (final status in const [kPlanItemOverdue, kPlanItemPartial, kPlanItemPending, kPlanItemPaid, kPlanItemCancelled])
        if (plan.countByStatus(status) > 0) (status, plan.countByStatus(status)),
    ];
    final note = _balanceNote();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Plan Toplamı', style: AppTypography.metadata)),
              Text('$activeCount${kNbsp}kalem', style: AppTypography.helper),
            ],
          ),
          const SizedBox(height: 2),
          MoneyText(plan.plannedTotal, currency: currency, style: AppTypography.metricPrimary),
          const SizedBox(height: AppSpacing.md),
          AppProgressBar(
            pct: plan.collectedPercent,
            color: AppColors.success,
            semanticsLabel: 'Plan tahsilat oranı',
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Figure(label: 'Tahsil Edilen', amount: plan.collectedTotal, currency: currency, color: AppColors.success),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _Figure(
                  label: 'Kalan',
                  amount: plan.remainingTotal,
                  currency: currency,
                  alignEnd: true,
                ),
              ),
            ],
          ),
          if (counts.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xs + 2,
              runSpacing: AppSpacing.xs + 2,
              children: [
                for (final (status, count) in counts)
                  StatusBadge(
                    label: '${planItemStatusLabel(status)} $count',
                    tone: kPlanItemStatuses[status]?.$2 ?? StatusTone.muted,
                  ),
              ],
            ),
          ],
          if (note != null) ...[
            const Divider(height: AppSpacing.xl),
            Text(note.text, style: AppTypography.helper.copyWith(color: note.color, height: 1.35)),
          ],
        ],
      ),
    );
  }

  /// Web `PaymentPlanSection` notunun aynısı (fark 0,005'ten küçükse yok).
  ({String text, Color color})? _balanceNote() {
    final cv = currentContractValue;
    if (cv == null || plan.items.isEmpty) return null;
    final diff = cv - plan.plannedTotal;
    if (diff.abs() < 0.005) return null;
    final cvText = Formatters.money(cv, currency: currency);
    if (diff > 0) {
      return (
        text: 'Ödeme planında ${Formatters.money(diff, currency: currency)} planlanmamış bakiye bulunmaktadır '
            '(güncel proje bedeli $cvText).',
        color: AppColors.warning,
      );
    }
    return (
      text: 'Plan toplamı güncel proje bedelinden ($cvText) farklı — özel plan oluşturulmuş olabilir.',
      color: AppColors.textMuted,
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.amount,
    required this.currency,
    this.color,
    this.alignEnd = false,
  });

  final String label;
  final double amount;
  final String currency;
  final Color? color;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTypography.helper),
        MoneyText(
          amount,
          currency: currency,
          color: color,
          style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
          textAlign: alignEnd ? TextAlign.right : TextAlign.left,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Tek kalem satırı: ad (+ yüzde), planlanan tutar, vade (+ gecikme
/// ipucu), durum, tahsilat çubuğu ve tahsil/kalan. İptal edilen kalem
/// soluk ve üstü çizili.
class PaymentPlanItemCard extends StatelessWidget {
  const PaymentPlanItemCard({
    super.key,
    required this.item,
    required this.currency,
    required this.today,
    this.onTap,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.sm),
  });

  final PaymentPlanItem item;
  final String currency;
  final DateTime today;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final cancelled = item.isCancelled;
    final overdue = item.isOverdue;
    final hint = item.isOpen ? dueHint(item.dueDate, today) : null;
    final percentage = item.percentage;

    return AppCard(
      onTap: onTap,
      margin: margin,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Opacity(
        opacity: cancelled ? 0.6 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: item.name,
                      children: [
                        if (percentage != null)
                          TextSpan(text: '  ${Formatters.percent(percentage)}', style: AppTypography.metadata),
                      ],
                    ),
                    style: AppTypography.cardTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                MoneyText(
                  item.plannedAmount,
                  currency: currency,
                  style: AppTypography.body.copyWith(
                    fontWeight: FontWeight.w700,
                    decoration: cancelled ? TextDecoration.lineThrough : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.event_outlined, size: 14, color: overdue ? AppColors.danger : AppColors.textMuted),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.dueDate == null ? 'Vadesiz' : 'Vade ${Formatters.date(item.dueDate)}',
                          style: AppTypography.metadata.copyWith(color: overdue ? AppColors.danger : null),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hint != null) ...[
                        const Text(' · ', style: AppTypography.metadata),
                        Flexible(child: DueHintText(hint: hint)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                StatusRegistry.build(item.status, kPlanItemStatuses),
              ],
            ),
            if (!cancelled) ...[
              const SizedBox(height: AppSpacing.sm),
              AppProgressBar(
                pct: item.collectedPercent,
                color: overdue ? AppColors.danger : AppColors.success,
                height: 5,
                semanticsLabel: 'Tahsilat oranı',
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Tahsil ${Formatters.money(item.collectedAmount, currency: currency)}',
                      style: AppTypography.helper,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    'Kalan ${Formatters.money(item.remainingAmount, currency: currency)}',
                    style: AppTypography.helper.copyWith(
                      fontWeight: FontWeight.w700,
                      color: overdue && item.remainingAmount > 0 ? AppColors.danger : AppColors.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
