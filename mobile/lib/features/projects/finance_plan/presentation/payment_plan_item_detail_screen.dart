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
import '../../../../core/widgets/app_data_row.dart';
import '../../../../core/widgets/app_lifecycle_actions.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/money_text.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../../core/widgets/viz/progress_bar.dart';
import '../../data/projects_providers.dart';
import '../../domain/project.dart';
import '../../finance_ledger/presentation/ledger_sections.dart' show addProjectCollection;
import '../../presentation/destructive_action_button.dart';
import '../data/finance_plan_providers.dart';
import '../domain/finance_dates.dart';
import '../domain/payment_plan.dart';
import '../finance_plan_paths.dart';
import 'widgets/finance_plan_ui.dart';

/// Ödeme planı kalemi detayı (`/projeler/:id/odeme-plani/:itemId`). Tekil
/// uç olmadığı için kalem, plan listesinden okunur. Düzenle / Kalemi İptal
/// Et yalnızca `projects.finance.manage` ile, açık (tamamlanmamış/iptal
/// edilmemiş) projede ve iptal edilmemiş kalemde görünür (web ile aynı
/// koşullar). İptal geri alınamaz; kaleme bağlı tahsilatlar silinmez.
class PaymentPlanItemDetailScreen extends ConsumerStatefulWidget {
  const PaymentPlanItemDetailScreen({super.key, required this.projectId, required this.itemId});

  final String projectId;
  final String itemId;

  @override
  ConsumerState<PaymentPlanItemDetailScreen> createState() => _PaymentPlanItemDetailScreenState();
}

class _PaymentPlanItemDetailScreenState extends ConsumerState<PaymentPlanItemDetailScreen> {
  bool _busy = false;

  PlanItemKey get _key => (projectId: widget.projectId, itemId: widget.itemId);

  Future<void> _refresh() async {
    ref.invalidate(projectPaymentPlanProvider(widget.projectId));
    try {
      await ref.read(paymentPlanItemProvider(_key).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    const fallbackTitle = Text('Ödeme Planı Kalemi');
    if (user == null && auth.isLoading) {
      return const AppPageScaffold(title: fallbackTitle, body: LoadingState());
    }
    if (!user.can(kFinancePlanReadPermission)) {
      return const AppPageScaffold(title: fallbackTitle, body: NoAccessView(message: kFinanceNoAccessText));
    }
    final canManage = user.can(kFinancePlanManagePermission);
    final itemAsync = ref.watch(paymentPlanItemProvider(_key));
    final project = ref.watch(projectDetailProvider(widget.projectId)).valueOrNull;
    final item = itemAsync.valueOrNull;
    // Proje durumu bilinmeden yazma aksiyonu gösterilmez.
    final locked = project == null || isFinanceLocked(project);
    final canEdit = canManage && !locked && item != null && !item.isCancelled;

    // AppBar varlık türünü söyler; kalemin (uzun olabilen) adı gövdenin
    // başlığında tam yazılır -- ad iki kez tekrarlanmaz. Düzenle tek yerde:
    // aksiyon çubuğunda.
    return AppPageScaffold(
      title: fallbackTitle,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: itemAsync.when(
          loading: () => const LoadingState(),
          error: (e, _) => isFinanceForbidden(e)
              ? const NoAccessView(message: kFinanceNoAccessText, scrollable: true)
              : FinanceScrollableCenter(child: ErrorState(error: e, onRetry: _refresh)),
          data: (item) => _buildBody(item, project, canManage: canManage, canEdit: canEdit),
        ),
      ),
    );
  }

  Widget _buildBody(PaymentPlanItem item, Project? project, {required bool canManage, required bool canEdit}) {
    final currency = project?.currency ?? 'TRY';
    final today = ref.watch(financePlanTodayProvider);
    final hint = item.isOpen ? dueHint(item.dueDate, today) : null;
    final cancelled = item.isCancelled;
    final percentage = item.percentage;
    final canCollect = canEdit && item.remainingAmount > 0;

    Widget? notice;
    if (project != null && isFinanceLocked(project)) {
      notice = FinanceLockedNotice(project: project);
    } else if (!canManage) {
      notice = const ReadOnlyNotice(kPaymentPlanReadOnlyText);
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(item.name, style: AppTypography.pageTitle)),
            const SizedBox(width: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: StatusRegistry.build(item.status, kPlanItemStatuses),
            ),
          ],
        ),
        if (percentage != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${Formatters.percent(percentage)} · ana sözleşme bedeli üzerinden hesaplandı',
            style: AppTypography.metadata,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Planlanan Tutar', style: AppTypography.metadata),
              const SizedBox(height: 2),
              MoneyText(
                item.plannedAmount,
                currency: currency,
                style: AppTypography.metricPrimary.copyWith(
                  decoration: cancelled ? TextDecoration.lineThrough : null,
                ),
              ),
              if (!cancelled) ...[
                const SizedBox(height: AppSpacing.md),
                AppProgressBar(
                  pct: item.collectedPercent,
                  color: item.isOverdue ? AppColors.danger : AppColors.success,
                  semanticsLabel: 'Tahsilat oranı',
                ),
                const SizedBox(height: AppSpacing.xs),
                Text('${Formatters.percent(item.collectedPercent)} tahsil edildi', style: AppTypography.helper),
                const Divider(height: AppSpacing.xl),
                AppDataRow(
                  label: 'Tahsil Edilen',
                  value: Formatters.money(item.collectedAmount, currency: currency),
                  valueColor: AppColors.success,
                ),
                AppDataRow(
                  label: 'Kalan',
                  value: Formatters.money(item.remainingAmount, currency: currency),
                  valueColor: item.isOverdue && item.remainingAmount > 0 ? AppColors.danger : null,
                ),
              ],
            ],
          ),
        ),
        if (!cancelled) _LinkedCollections(projectId: widget.projectId, itemId: item.id, currency: currency),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppDataRow(
                label: 'Vade',
                value: item.dueDate == null ? 'Vadesiz' : Formatters.date(item.dueDate),
                valueColor: item.isOverdue ? AppColors.danger : null,
              ),
              if (hint != null) AppDataRow(label: 'Vade Durumu', trailing: DueHintText(hint: hint)),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        const Text('Notlar', style: AppTypography.sectionTitle),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Text(
            item.notes.isEmpty ? 'Not yok.' : item.notes,
            style: item.notes.isEmpty ? AppTypography.metadata : AppTypography.body,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          cancelled
              ? 'Bu kalem iptal edildi; plan toplamına dahil değildir.'
              : 'Tahsil edilen tutar, bu kaleme bağlanan tahsilatlardan hesaplanır.',
          style: AppTypography.helper,
        ),
        if (notice != null) ...[const SizedBox(height: AppSpacing.lg), notice],
        if (canEdit) ...[
          const SizedBox(height: AppSpacing.xl),
          AppLifecycleActions(
            actions: [
              // Açık bakiyesi olan kalemde olağan sonraki adım tahsilatı
              // kaydetmektir: form bu kaleme bağlı açılır.
              if (canCollect)
                AppLifecycleAction(
                  label: 'Tahsilat Ekle',
                  icon: Icons.payments_outlined,
                  primary: true,
                  onPressed: _busy || project == null
                      ? null
                      : () => addProjectCollection(context, project, initialPlanItemId: item.id),
                ),
              AppLifecycleAction(
                label: 'Düzenle',
                icon: Icons.edit_outlined,
                primary: !canCollect,
                onPressed: _busy ? null : () => context.push(paymentPlanItemEditPath(widget.projectId, item.id)),
              ),
            ],
          ),
          // Geri alınamaz iptal çubuktan ayrı, kırmızı.
          const SizedBox(height: AppSpacing.sm),
          DestructiveActionButton(
            label: 'Kalemi İptal Et',
            loading: _busy,
            onPressed: _busy ? null : () => _cancel(item),
          ),
        ],
      ],
    );
  }

  Future<void> _cancel(PaymentPlanItem item) async {
    final ok = await confirmFinanceAction(
      context,
      title: 'Kalemi İptal Et',
      message: '"${item.name}" kalemi iptal edilecek. İptal edilen kalem plan toplamından düşer; bu kaleme bağlı '
          'tahsilatlar silinmez. Bu işlem geri alınamaz.',
      confirmLabel: 'İptal Et',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await container.read(financePlanRepositoryProvider).cancelPlanItem(widget.projectId, item.id);
      invalidatePaymentPlan(container, widget.projectId);
      messenger.showSnackBar(const SnackBar(content: Text('Ödeme planı kalemi iptal edildi.')));
    } catch (e) {
      if (isFinanceConflict(e)) invalidateFinancePlanProject(container, widget.projectId);
      if (isFinanceNotFound(e)) invalidatePaymentPlan(container, widget.projectId);
      messenger.showSnackBar(SnackBar(content: Text(financePlanErrorText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Bu kaleme bağlı (iptal edilmemiş) tahsilatlar -- "Tahsil Edilen" rakamının
/// dökümü. Liste yüklenemezse (izin/ağ) bölüm sessizce gizlenir; rakamın
/// kendisi zaten plan ucundan gelir.
class _LinkedCollections extends ConsumerWidget {
  const _LinkedCollections({required this.projectId, required this.itemId, required this.currency});

  final String projectId;
  final String itemId;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(projectCollectionsProvider(projectId)).valueOrNull;
    if (all == null) return const SizedBox.shrink();
    final linked = [for (final c in all) if (c.paymentPlanItemId == itemId && !c.isVoided) c];
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: AppCard(
        key: const ValueKey('plan-item-linked-collections'),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text('Bağlı Tahsilatlar', style: AppTypography.cardTitle),
            ),
            if (linked.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text('Bu kaleme bağlı tahsilat yok.', style: AppTypography.metadata),
              )
            else
              for (final c in linked)
                AppDataRow(
                  label: [
                    Formatters.date(c.receivedDate),
                    if (c.paymentMethod.isNotEmpty) c.paymentMethod,
                  ].join(' · '),
                  value: Formatters.money(c.amount, currency: c.currency.isEmpty ? currency : c.currency),
                ),
          ],
        ),
      ),
    );
  }
}
