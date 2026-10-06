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
import '../../../../core/widgets/app_data_row.dart';
import '../../../../core/widgets/app_lifecycle_actions.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/money_text.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../data/projects_providers.dart';
import '../../domain/project.dart';
import '../../presentation/destructive_action_button.dart';
import '../../finance_ledger/data/finance_ledger_providers.dart';
import '../data/finance_plan_providers.dart';
import '../domain/project_invoice.dart';
import '../finance_plan_paths.dart';
import 'widgets/finance_plan_ui.dart';
import '../../../../core/widgets/app_sheet.dart';

/// Fatura detayı (`/projeler/:id/faturalar/:invoiceId`). Tekil uç olmadığı
/// için fatura, proje fatura listesinden okunur. Fatura alanları
/// DÜZENLENEMEZ (backend'de uç yok, web'de de yok); yalnızca durum değişir.
///
/// Durum aksiyonları yalnızca `projects.finance.manage` ile ve açık
/// projede görünür (web: kilitli projede durum seçicisi yerine rozet).
/// Backend'de durum makinesi olmadığından web'deki gibi her durum
/// seçilebilir; olağan akışın sonraki adımı birincil düğmedir.
class InvoiceDetailScreen extends ConsumerStatefulWidget {
  const InvoiceDetailScreen({super.key, required this.projectId, required this.invoiceId});

  final String projectId;
  final String invoiceId;

  @override
  ConsumerState<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends ConsumerState<InvoiceDetailScreen> {
  bool _busy = false;

  InvoiceKey get _key => (projectId: widget.projectId, invoiceId: widget.invoiceId);

  Future<void> _refresh() async {
    ref.invalidate(projectInvoicesProvider(widget.projectId));
    try {
      await ref.read(projectInvoiceProvider(_key).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    const fallbackTitle = Text('Fatura');
    if (user == null && auth.isLoading) {
      return const AppPageScaffold(title: fallbackTitle, body: LoadingState());
    }
    if (!user.can(kFinancePlanReadPermission)) {
      return const AppPageScaffold(title: fallbackTitle, body: NoAccessView(message: kFinanceNoAccessText));
    }
    final canManage = user.can(kFinancePlanManagePermission);
    final invoiceAsync = ref.watch(projectInvoiceProvider(_key));
    final project = ref.watch(projectDetailProvider(widget.projectId)).valueOrNull;
    final invoice = invoiceAsync.valueOrNull;

    // Fatura numarası YALNIZCA AppBar'da (gövdede ikinci bir başlık olarak
    // tekrarlanmaz -- 360 dp'de ilk ekranı boşa harcıyordu).
    return AppPageScaffold(
      title: invoice == null ? fallbackTitle : Text(invoice.invoiceNo, maxLines: 1, overflow: TextOverflow.ellipsis),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: invoiceAsync.when(
          loading: () => const LoadingState(),
          error: (e, _) => isFinanceForbidden(e)
              ? const NoAccessView(message: kFinanceNoAccessText, scrollable: true)
              : FinanceScrollableCenter(child: ErrorState(error: e, onRetry: _refresh)),
          data: (invoice) => _buildBody(invoice, project, canManage),
        ),
      ),
    );
  }

  Widget _buildBody(ProjectInvoice invoice, Project? project, bool canManage) {
    final today = ref.watch(financePlanTodayProvider);
    final overdue = invoice.isOverdueOn(today);
    // Proje durumu bilinmeden yazma aksiyonu gösterilmez.
    final locked = project == null || isFinanceLocked(project);
    final canChange = canManage && !locked;

    Widget? notice;
    if (project != null && isFinanceLocked(project)) {
      notice = FinanceLockedNotice(project: project);
    } else if (!canManage) {
      notice = const ReadOnlyNotice(kInvoicesReadOnlyText);
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        Row(
          children: [
            StatusBadge(label: '${invoiceTypeLabel(invoice.invoiceType)} Faturası', tone: StatusTone.muted),
            const SizedBox(width: AppSpacing.sm),
            StatusRegistry.build(invoice.status, kInvoiceStatuses),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Tutar', style: AppTypography.metadata),
              const SizedBox(height: 2),
              MoneyText(
                invoice.amount,
                currency: invoice.currency,
                style: AppTypography.metricPrimary.copyWith(
                  decoration: invoice.isCancelled ? TextDecoration.lineThrough : null,
                ),
              ),
              const Divider(height: AppSpacing.xl),
              AppDataRow(label: 'Fatura Tarihi', value: Formatters.date(invoice.invoiceDate)),
              AppDataRow(
                label: 'Vade',
                value: invoice.dueDate == null ? '—' : Formatters.date(invoice.dueDate),
                valueColor: overdue ? AppColors.danger : null,
              ),
              AppDataRow(
                // Alış faturasında karşı taraf tedarikçidir.
                label: invoice.isSales ? 'Müşteri / Firma' : 'Tedarikçi / Firma',
                value: invoice.customerName.isEmpty ? '—' : invoice.customerName,
                multiline: true,
              ),
              if (invoice.createdAt.isNotEmpty)
                AppDataRow(label: 'Kayıt Tarihi', value: Formatters.dateTime(invoice.createdAt)),
            ],
          ),
        ),
        if (overdue) ...[
          const SizedBox(height: AppSpacing.md),
          const FinanceAlertStrip(
            text: 'Vadesi geçti',
            detail: 'Satış faturası kesilmiş/gönderilmiş ama vadesinde ödenmemiş görünüyor. Ödeme alındıysa '
                'durumunu "Ödendi" yap.',
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        const Text('Notlar', style: AppTypography.sectionTitle),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Text(
            invoice.notes.isEmpty ? 'Not yok.' : invoice.notes,
            style: invoice.notes.isEmpty ? AppTypography.metadata : AppTypography.body,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const Text(
          'Fatura bilgileri kayıttan sonra değiştirilemez; yalnızca durumu güncellenir.',
          style: AppTypography.helper,
        ),
        if (notice != null) ...[const SizedBox(height: AppSpacing.lg), notice],
        if (canChange) ...[
          const SizedBox(height: AppSpacing.xl),
          AppLifecycleActions(actions: _actions(invoice, today)),
          // Geri alınamaz iptal çubuktan ayrı, kırmızı.
          if (!invoice.isCancelled) ...[
            const SizedBox(height: AppSpacing.sm),
            DestructiveActionButton(
              label: 'Faturayı İptal Et',
              loading: _busy,
              onPressed: _busy ? null : () => _changeStatus(invoice, kInvoiceCancelled),
            ),
          ],
        ],
      ],
    );
  }

  List<AppLifecycleAction> _actions(ProjectInvoice invoice, DateTime today) {
    // Türe ve vadeye göre sonraki adım: alışta "Gönderildi" yok, vadesi
    // geçmiş satış faturasında doğrudan "Ödendi" (şeridin önerdiği adım).
    final next = nextInvoiceStatus(invoice, today);
    return [
      if (next != null)
        AppLifecycleAction(
          // İkon YOK: PrimaryButton ikonlu etiketi esnemeyen bir Row'a koyar;
          // uzun etiket büyük yazı boyutunda taşardı. İkonsuz etiket düğme
          // genişliğine sığdırılır.
          label: '${invoiceStatusLabel(next)} Olarak İşaretle',
          primary: true,
          loading: _busy,
          onPressed: _busy ? null : () => _changeStatus(invoice, next),
        ),
      AppLifecycleAction(
        label: 'Durumu Değiştir',
        icon: Icons.swap_horiz,
        loading: _busy,
        onPressed: _busy ? null : () => _pickStatus(invoice),
      ),
    ];
  }

  Future<void> _pickStatus(ProjectInvoice invoice) async {
    final picked = await showAppSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.sm),
              child: Text('Fatura Durumu', style: AppTypography.sectionTitle),
            ),
            // İptal burada YOK: ayrı, onaylı "Faturayı İptal Et" düğmesi var.
            // Her durum bir kez yazılır; sabit genişlikli renkli nokta
            // etiketleri aynı hizada tutar (rozet + başlık ikilisi hem durumu
            // iki kez yazıyor hem de metinleri farklı x'lerden başlatıyordu).
            for (final entry in kInvoiceStatuses.entries)
              if (entry.key != kInvoiceCancelled)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                  minLeadingWidth: 12,
                  leading: _StatusDot(tone: entry.value.$2),
                  title: Text(entry.value.$1),
                  trailing: entry.key == invoice.status ? const Icon(Icons.check, color: AppColors.gold) : null,
                  selected: entry.key == invoice.status,
                  onTap: () => Navigator.of(sheetContext).pop(entry.key),
                ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (picked == null || picked == invoice.status || !mounted) return;
    await _changeStatus(invoice, picked);
  }

  Future<void> _changeStatus(ProjectInvoice invoice, String status) async {
    final cancelling = status == kInvoiceCancelled;
    final sales = invoice.invoiceType == kInvoiceTypeSales;
    bool? recordCollection;
    if (sales && status == kInvoicePaid) {
      // Proje özetinin "tahsil edilen"i ve kârı tahsilatlardan hesaplanır;
      // faturanın durumu para girişi sayılmaz (sahada 2026-10: "ödendi
      // yaptım ama özette veri yok"). Tahsilat ayrıca girildiyse çift
      // sayılmasın diye sorulur.
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Fatura ödendi'),
          content: Text(
            '"${invoice.invoiceNo}" ödendi olarak işaretlenecek. Proje özetindeki tahsilat ve kâr, tahsilat '
            'kayıtlarından hesaplanır.\n\n${Formatters.money(invoice.amount, currency: invoice.currency)} '
            'tahsilat olarak da kaydedilsin mi?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Vazgeç')),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Tahsilatı zaten girdim'),
            ),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Tahsilat da kaydet')),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      recordCollection = choice;
    } else {
      final unpaying = sales && invoice.status == kInvoicePaid;
      final ok = await confirmFinanceAction(
        context,
        title: cancelling ? 'Faturayı İptal Et' : 'Fatura Durumu',
        message: [
          cancelling
              ? '"${invoice.invoiceNo}" faturası iptal edilecek. İptal edilen fatura kesilen fatura toplamına dahil '
                  'edilmez.'
              : '"${invoice.invoiceNo}" faturasının durumu "${invoiceStatusLabel(status)}" olarak değiştirilsin mi?',
          if (unpaying) 'Bu fatura ödendi işaretlenirken otomatik açılan tahsilat varsa iptal edilir.',
        ].join('\n\n'),
        confirmLabel: cancelling ? 'İptal Et' : 'Değiştir',
        danger: cancelling,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await container
          .read(financePlanRepositoryProvider)
          .updateInvoiceStatus(widget.projectId, invoice.id, status, recordCollection: recordCollection);
      invalidateInvoices(container, widget.projectId);
      // Tahsilat açılmış/iptal edilmiş olabilir: tahsilat listesi ve özet de tazelenir.
      invalidateProjectLedger(container.invalidate, widget.projectId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            recordCollection == true
                ? 'Fatura ödendi; ${Formatters.money(invoice.amount, currency: invoice.currency)} tahsilat kaydedildi.'
                : 'Fatura durumu "${invoiceStatusLabel(status)}" olarak güncellendi.',
          ),
        ),
      );
    } catch (e) {
      if (isFinanceConflict(e)) invalidateFinancePlanProject(container, widget.projectId);
      if (isFinanceNotFound(e)) invalidateInvoices(container, widget.projectId);
      messenger.showSnackBar(SnackBar(content: Text(financePlanErrorText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Durum seçicisindeki sabit genişlikli renk noktası (rozet tonuyla aynı).
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.tone});

  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      StatusTone.gold => AppColors.gold,
      StatusTone.success => AppColors.success,
      StatusTone.danger => AppColors.danger,
      StatusTone.info => AppColors.info,
      StatusTone.muted => AppColors.textMuted,
      StatusTone.warning => AppColors.warning,
    };
    return Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}
