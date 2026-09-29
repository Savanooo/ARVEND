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
import '../../../../core/widgets/app_filter_bar.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/money_text.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../data/projects_providers.dart';
import '../../domain/project.dart';
import '../data/finance_plan_providers.dart';
import '../domain/project_invoice.dart';
import '../finance_plan_paths.dart';
import 'widgets/finance_plan_ui.dart';

/// Faturalar -- web `InvoicesSection` ("Fatura Bilgileri",
/// projeler/[id]/FinanceSections.tsx) karşılığı. Proje detayının Finans
/// grubunda alt görünüm (`?grup=finans&alt=faturalar`) ve tam ekran
/// (`/projeler/:id/faturalar`). Okuma `projects.finance.read`, fatura
/// ekleme ve durum değiştirme `projects.finance.manage` ister.
///
/// Vadesi geçen satış faturaları (Kesildi/Gönderildi durumunda) ana
/// sayfadaki "satış faturasının vadesi geçti" kuralıyla aynı biçimde
/// kırmızı vurgulanır.
class InvoicesTab extends ConsumerStatefulWidget {
  const InvoicesTab({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<InvoicesTab> createState() => _InvoicesTabState();
}

enum InvoiceTypeFilter { all, sales, purchase }

class _InvoicesTabState extends ConsumerState<InvoicesTab> {
  InvoiceTypeFilter _filter = InvoiceTypeFilter.all;

  Future<void> _refresh() async {
    ref.invalidate(projectInvoicesProvider(widget.projectId));
    try {
      await ref.read(projectInvoicesProvider(widget.projectId).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (user == null && auth.isLoading) return const LoadingState();
    if (!user.can(kFinancePlanReadPermission)) {
      return const NoAccessView(message: kFinanceNoAccessText, scrollable: true);
    }
    final canManage = user.can(kFinancePlanManagePermission);
    final projectAsync = ref.watch(projectDetailProvider(widget.projectId));
    final invoicesAsync = ref.watch(projectInvoicesProvider(widget.projectId));

    return RefreshIndicator(
      onRefresh: _refresh,
      child: invoicesAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isFinanceForbidden(e)
            ? const NoAccessView(message: kFinanceNoAccessText, scrollable: true)
            : FinanceScrollableCenter(child: ErrorState(error: e, onRetry: _refresh)),
        data: (invoices) => projectAsync.when(
          loading: () => const LoadingState(),
          error: (e, _) => isFinanceForbidden(e)
              ? const NoAccessView(message: kFinanceNoAccessText, scrollable: true)
              : FinanceScrollableCenter(
                  child: ErrorState(
                    error: e,
                    onRetry: () async => ref.invalidate(projectDetailProvider(widget.projectId)),
                  ),
                ),
          data: (project) => _buildBody(project, invoices, canManage),
        ),
      ),
    );
  }

  Widget _buildBody(Project project, List<ProjectInvoice> invoices, bool canManage) {
    final today = ref.watch(financePlanTodayProvider);
    final locked = isFinanceLocked(project);
    final canAdd = canManage && !locked;
    final salesCount = invoices.where((i) => i.isSales).length;
    final overdueCount = invoices.where((i) => i.isOverdueOn(today)).length;
    final visible = switch (_filter) {
      InvoiceTypeFilter.all => invoices,
      InvoiceTypeFilter.sales => [for (final i in invoices) if (i.isSales) i],
      InvoiceTypeFilter.purchase => [for (final i in invoices) if (!i.isSales) i],
    };

    final notice = locked
        ? FinanceLockedNotice(project: project)
        : (!canManage ? const ReadOnlyNotice(kInvoicesReadOnlyText) : null);

    AppFilterChipData chip(String label, InvoiceTypeFilter value, int count) => AppFilterChipData(
          label: '$label ($count)',
          selected: _filter == value,
          onTap: () => setState(() => _filter = value),
        );

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        if (overdueCount > 0) ...[
          FinanceAlertStrip(
            text: '$overdueCount satış faturasının vadesi geçti',
            detail: 'Kesildi veya Gönderildi durumunda, vadesi geçmiş ve henüz ödenmemiş satış faturaları.',
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (notice != null) ...[notice, const SizedBox(height: AppSpacing.md)],
        // Başlık listeyi anlatır: "Faturalar" zaten AppBar'da (tam ekran) ya da
        // seçili çipte (proje detayı) yazılı.
        AppSectionHeader(
          title: 'Fatura Listesi',
          trailing: canAdd
              ? TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Fatura Ekle'),
                  onPressed: () => context.push(invoiceNewPath(widget.projectId)),
                )
              : null,
        ),
        if (invoices.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          AppFilterBar(
            chips: [
              chip('Tümü', InvoiceTypeFilter.all, invoices.length),
              chip('Satış', InvoiceTypeFilter.sales, salesCount),
              chip('Alış', InvoiceTypeFilter.purchase, invoices.length - salesCount),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        if (invoices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: EmptyStateView(message: 'Henüz fatura kaydı yok.', icon: Icons.receipt_long_outlined),
          )
        else if (visible.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: EmptyStateView(message: 'Bu türde fatura yok.', icon: Icons.receipt_long_outlined),
          )
        else
          for (final invoice in visible)
            InvoiceCard(
              invoice: invoice,
              overdue: invoice.isOverdueOn(today),
              onTap: () => context.push(invoicePath(widget.projectId, invoice.id)),
            ),
      ],
    );
  }
}

/// Tam ekran Faturalar (`/projeler/:id/faturalar`).
class InvoicesScreen extends StatelessWidget {
  const InvoicesScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(title: const Text('Faturalar'), body: InvoicesTab(projectId: projectId));
  }
}

/// Tek fatura satırı: numara, tür + tarih, vade (gecikmişse kırmızı),
/// durum rozeti ve tutar. İptal edilen faturanın tutarı üstü çizili.
class InvoiceCard extends StatelessWidget {
  const InvoiceCard({
    super.key,
    required this.invoice,
    required this.overdue,
    this.onTap,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.sm),
  });

  final ProjectInvoice invoice;
  final bool overdue;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final due = invoice.dueDate;
    final cancelled = invoice.isCancelled;
    return AppCard(
      onTap: onTap,
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: (invoice.isSales ? AppColors.gold : AppColors.info).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              invoice.isSales ? Icons.north_east : Icons.south_west,
              size: 18,
              color: invoice.isSales ? AppColors.gold : AppColors.info,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        invoice.invoiceNo,
                        style: AppTypography.cardTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    StatusRegistry.build(invoice.status, kInvoiceStatuses),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${invoiceTypeLabel(invoice.invoiceType)} · ${Formatters.date(invoice.invoiceDate)}',
                        style: AppTypography.metadata,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    MoneyText(
                      invoice.amount,
                      currency: invoice.currency,
                      style: AppTypography.body.copyWith(
                        fontWeight: FontWeight.w700,
                        decoration: cancelled ? TextDecoration.lineThrough : null,
                        color: cancelled ? AppColors.textMuted : null,
                      ),
                    ),
                  ],
                ),
                if (due != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    overdue ? 'Vadesi geçti · ${Formatters.date(due)}' : 'Vade ${Formatters.date(due)}',
                    style: overdue
                        ? AppTypography.metadata.copyWith(color: AppColors.danger, fontWeight: FontWeight.w700)
                        : AppTypography.helper,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
