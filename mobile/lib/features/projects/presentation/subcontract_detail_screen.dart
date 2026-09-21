import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_status_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_financial_summary.dart';
import '../../../core/widgets/app_lifecycle_actions.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/metric_card.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/subcontract.dart';
import 'subcontract_payment_form_sheet.dart';

/// Sprint 5 — Taşeron Sözleşmesi detayı. P2 ile hakediş (Progress Claim) ve
/// değişiklik emri (Subcontract Change Order) artık YALNIZCA OKUMA değil --
/// her ikisi de kendi detay/form ekranlarına sahiptir (bkz.
/// `progress_claim_detail_screen.dart`, `subcontract_change_order_detail_
/// screen.dart`). SOV kalemlerinin KENDİSİ hâlâ salt-okunur (P1'in bilinçli
/// kapsam sınırı korunur). Ödeme kaydı (GERÇEK nakit çıkışı) bu ekranda
/// AYRI kalır -- backend Sprint 5 follow-up'ın (migration 0039) mobildeki
/// karşılığı.
///
/// current_value/certified_to_date/remaining_commitment (taahhüt ekseni) ile
/// paid_to_date/remaining_payable (nakit ekseni) BİLİNÇLİ OLARAK AYRI
/// gösterilir -- sertifikasyon ödeme DEĞİLDİR, ikisi TEK bir rakamda
/// BİRLEŞTİRİLMEZ (bkz. backend SubcontractValueSummary yorumu). P3: hiyerarşi
/// Header -> Ticari Özet -> SOV -> Hakedişler -> Değişiklik Emirleri ->
/// Ödemeler -> Aksiyonlar (bkz. Faz 3 ürün brief'i) -- yalnızca sunum katmanı,
/// hiçbir rakam burada yeniden hesaplanmaz.
class SubcontractDetailScreen extends ConsumerWidget {
  const SubcontractDetailScreen({super.key, required this.projectId, required this.subcontractId});
  final String projectId;
  final String subcontractId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, subcontractId: subcontractId);
    final detailAsync = ref.watch(subcontractDetailProvider(args));

    return AppPageScaffold(
      title: detailAsync.maybeWhen(
        data: (d) => Text(d.subcontract.subcontractNo),
        orElse: () => const Text('Taşeron Sözleşmesi'),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(subcontractDetailProvider(args)),
        data: (context, detail) => _SubcontractDetailBody(projectId: projectId, subcontractId: subcontractId, detail: detail),
      ),
    );
  }
}

class _SubcontractDetailBody extends ConsumerWidget {
  const _SubcontractDetailBody({required this.projectId, required this.subcontractId, required this.detail});
  final String projectId;
  final String subcontractId;
  final ({Subcontract subcontract, List<SubcontractItem> items, SubcontractValue value}) detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, subcontractId: subcontractId);
    final paymentsAsync = ref.watch(subcontractPaymentsProvider(args));
    final claimsAsync = ref.watch(subcontractProgressClaimsProvider(args));
    final changeOrdersAsync = ref.watch(subcontractChangeOrdersProvider(args));
    // Yalnızca SOV kalemlerinde maliyet kodunu ham id yerine isimle
    // göstermek için -- zaten formun tedarikçi/maliyet kodu seçicisinde
    // kullanılan aynı salt-okunur provider, yeni bir repository çağrısı
    // DEĞİL.
    final costCodesAsync = ref.watch(orgCostCodesProvider);
    final sc = detail.subcontract;
    final value = detail.value;
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontracts.manage');
    final canApprove =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontracts.approve');
    final canManageClaims =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontract_claims.manage');
    final canManagePayments =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontract_payments.manage');
    final hasLifecycleActions = (sc.isEditable && canManage) ||
        (sc.canActivate && canApprove) ||
        (sc.canCancel && canApprove) ||
        (sc.canComplete && canApprove) ||
        (sc.canTerminate && canApprove);

    final costCodeLabels = {
      for (final c in costCodesAsync.valueOrNull ?? const <OrgCostCode>[])
        c.id: c.code.isNotEmpty ? '${c.code} — ${c.name}' : c.name,
    };

    void refreshAll() {
      ref.invalidate(subcontractDetailProvider(args));
      ref.invalidate(subcontractPaymentsProvider(args));
      ref.invalidate(subcontractProgressClaimsProvider(args));
      ref.invalidate(subcontractChangeOrdersProvider(args));
      // Yeni-modül taşeron ödemeleri financial-summary/cost-control'e
      // AKAR (migration 0039 follow-up) -- proje özetinin bayatlamaması
      // için bunlar da tazelenir (Tahsilat akışıyla AYNI ilke). Yaşam
      // döngüsü aksiyonları (activate/complete/cancel/terminate/değişiklik
      // emri onayı) commitment senkronizasyonu yaptığından + liste
      // sekmesindeki durum rozetinin bayatlamaması için subcontracts
      // listesi de tazelenir.
      ref.invalidate(projectFinancialSummaryProvider(projectId));
      ref.invalidate(projectCostControlProvider(projectId));
      ref.invalidate(projectSubcontractsProvider(projectId));
    }

    return RefreshIndicator(
      onRefresh: () async {
        refreshAll();
      },
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _Header(subcontract: sc),
          const SizedBox(height: AppSpacing.lg),
          const AppSectionHeader(title: 'Ticari Özet'),
          const SizedBox(height: AppSpacing.sm),
          _CommercialSummary(subcontract: sc, value: value),
          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: 'Kalemler (SOV)'),
          const SizedBox(height: AppSpacing.sm),
          _SovList(items: detail.items, currency: sc.currency, costCodeLabels: costCodeLabels),
          const SizedBox(height: AppSpacing.xl),
          AppSectionHeader(
            title: 'Hakedişler',
            trailing: sc.status == Subcontract.statusActive && canManageClaims
                ? TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Hakediş Ekle'),
                    onPressed: () => context.push('/projeler/$projectId/taseronlar/$subcontractId/hakedisler/yeni'),
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          AsyncStateView(
            value: claimsAsync,
            onRetry: () async => ref.invalidate(subcontractProgressClaimsProvider(args)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const _EmptySectionText('Henüz hakediş yok.'),
            data: (context, claims) => Column(
              children: [
                for (final c in claims)
                  AppListCard(
                    title: c.claimNumber,
                    trailing: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StatusRegistry.build(c.status, StatusRegistry.progressClaim),
                        const SizedBox(height: 2),
                        MoneyText(c.netPayable, currency: sc.currency, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
                      ],
                    ),
                    onTap: () => context.push('/projeler/$projectId/taseronlar/$subcontractId/hakedisler/${c.id}'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppSectionHeader(
            title: 'Değişiklik Emirleri',
            trailing: sc.status == Subcontract.statusActive && canManage
                ? TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Değişiklik Emri Ekle'),
                    onPressed: () =>
                        context.push('/projeler/$projectId/taseronlar/$subcontractId/degisiklik-emirleri/yeni'),
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          AsyncStateView(
            value: changeOrdersAsync,
            onRetry: () async => ref.invalidate(subcontractChangeOrdersProvider(args)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const _EmptySectionText('Henüz değişiklik emri yok.'),
            data: (context, changeOrders) => Column(
              children: [
                for (final co in changeOrders)
                  AppListCard(
                    title: '${co.number} — ${co.title}',
                    trailing: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StatusRegistry.build(co.status, StatusRegistry.subcontractChangeOrder),
                        const SizedBox(height: 2),
                        Text(
                          '${co.signedAmount >= 0 ? '+' : ''}${Formatters.money(co.signedAmount, currency: sc.currency)}',
                          style: AppTypography.body.copyWith(
                            fontWeight: FontWeight.w700,
                            color: co.changeType == SubcontractChangeOrder.typeAddition
                                ? AppStatusColors.success
                                : AppStatusColors.error,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    onTap: () =>
                        context.push('/projeler/$projectId/taseronlar/$subcontractId/degisiklik-emirleri/${co.id}'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppSectionHeader(
            title: 'Ödemeler',
            trailing: canManagePayments
                ? TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Ödeme Ekle'),
                    onPressed: () async {
                      final created = await showSubcontractPaymentFormSheet(
                        context,
                        projectId,
                        subcontractId,
                        currency: sc.currency,
                      );
                      if (created != null) refreshAll();
                    },
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          AsyncStateView(
            value: paymentsAsync,
            onRetry: () async => ref.invalidate(subcontractPaymentsProvider(args)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const _EmptySectionText('Henüz ödeme kaydı yok.'),
            data: (context, payments) => Column(
              children: [
                for (final p in payments)
                  AppListCard(
                    title: p.paymentMethod.isEmpty ? 'Ödeme' : p.paymentMethod,
                    subtitle: [
                      Formatters.date(p.paidDate),
                      if (p.description.isNotEmpty) p.description,
                      if (p.referenceNo.isNotEmpty) p.referenceNo,
                    ].join(' · '),
                    trailing: MoneyText(
                      p.amount,
                      currency: sc.currency,
                      style: AppTypography.body.copyWith(
                        fontWeight: FontWeight.w700,
                        decoration: p.isVoided ? TextDecoration.lineThrough : null,
                      ),
                      color: p.isVoided ? AppStatusColors.neutral : AppStatusColors.success,
                    ),
                  ),
              ],
            ),
          ),
          if (hasLifecycleActions) ...[
            const SizedBox(height: AppSpacing.xl),
            const AppSectionHeader(title: 'Aksiyonlar'),
            const SizedBox(height: AppSpacing.sm),
            _LifecycleActionsBar(
              projectId: projectId,
              subcontractId: subcontractId,
              subcontract: sc,
              canManage: canManage,
              canApprove: canApprove,
              onChanged: refreshAll,
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.subcontract});
  final Subcontract subcontract;

  @override
  Widget build(BuildContext context) {
    final sc = subcontract;
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sc.supplierName ?? sc.supplierCode ?? '-',
                  style: AppTypography.cardTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (sc.title.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(sc.title, style: AppTypography.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
                if (sc.scopeSummary.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(sc.scopeSummary, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          StatusRegistry.build(sc.status, StatusRegistry.subcontract),
        ],
      ),
    );
  }
}

/// Ticari özet -- backend `SubcontractValue`'nun (`current_value` alt
/// nesnesi) HER ZAMAN otoriter rakamlarını yalnızca DÜZENLER, hiçbir
/// toplam/oran burada yeniden hesaplanmaz. `certifiedUnpaid`/`approvedNet`/
/// `pendingNet` de yalnızca zaten backend'den gelen iki rakamın GÖSTERİM
/// AMAÇLI farkıdır (yeni bir formül DEĞİL) -- bkz. Faz 3 ürün brief'i.
class _CommercialSummary extends StatelessWidget {
  const _CommercialSummary({required this.subcontract, required this.value});
  final Subcontract subcontract;
  final SubcontractValue value;

  @override
  Widget build(BuildContext context) {
    final currency = subcontract.currency;
    final approvedNet = value.approvedAdditions - value.approvedDeductions;
    final pendingNet = value.pendingAdditions - value.pendingDeductions;
    final certifiedUnpaid = value.certifiedToDate - value.paidToDate;

    return AppFinancialSummary(
      headline: Row(
        children: [
          Expanded(
            child: MetricCard(
              label: 'Güncel Değer',
              value: Formatters.money(value.currentValue, currency: currency),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: MetricCard(
              label: 'Kalan Taahhüt',
              value: Formatters.money(value.remainingCommitment, currency: currency),
              valueColor: AppStatusColors.info,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: MetricCard(
              label: 'Sertifikalı, Ödenmemiş',
              value: Formatters.money(certifiedUnpaid, currency: currency),
              valueColor: certifiedUnpaid > 0 ? AppStatusColors.warning : null,
            ),
          ),
        ],
      ),
      rows: [
        AppDataRow(label: 'Orijinal Sözleşme Değeri', value: Formatters.money(value.originalAmount, currency: currency)),
        AppDataRow(
          label: 'Onaylı Ek İşler (net)',
          value: '${approvedNet >= 0 ? '+' : ''}${Formatters.money(approvedNet, currency: currency)}',
          valueColor: approvedNet > 0
              ? AppStatusColors.success
              : (approvedNet < 0 ? AppStatusColors.error : null),
        ),
        if (value.pendingAdditions != 0 || value.pendingDeductions != 0)
          AppDataRow(
            label: 'Onay Bekleyen Ek İşler (net)',
            value: '${pendingNet >= 0 ? '+' : ''}${Formatters.money(pendingNet, currency: currency)}',
            valueColor: AppStatusColors.warning,
          ),
        AppDataRow(label: 'Sertifikalı Toplam', value: Formatters.money(value.certifiedToDate, currency: currency)),
        AppDataRow(label: 'Ödenen Toplam', value: Formatters.money(value.paidToDate, currency: currency)),
        AppDataRow(
          label: 'Kalan Ödenecek',
          value: Formatters.money(value.remainingPayable, currency: currency),
          emphasize: true,
        ),
        if (subcontract.retentionPercent != null)
          AppDataRow(
            label: 'Hakediş Kesintisi (Retention)',
            value: '%${subcontract.retentionPercent!.toStringAsFixed(2)}',
          ),
        if (subcontract.advanceAmount != null)
          AppDataRow(label: 'Avans Tutarı', value: Formatters.money(subcontract.advanceAmount!, currency: currency)),
      ],
    );
  }
}

/// SOV/İş kalemleri -- yalnızca tarama için gerekli alanlar (açıklama,
/// maliyet kodu ADI, tutar, varsa miktar/birim). id/wbsNodeId/budgetLineId
/// gibi teknik alanlar KASITLI OLARAK gösterilmez (bkz. Faz 3 ürün brief'i
/// "veritabanı benzeri ID gösterme").
class _SovList extends StatelessWidget {
  const _SovList({required this.items, required this.currency, required this.costCodeLabels});
  final List<SubcontractItem> items;
  final String currency;
  final Map<String, String> costCodeLabels;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _EmptySectionText('Kalem yok.');
    return Column(
      children: [
        for (final item in items)
          AppListCard(
            title: item.description,
            subtitle: _subtitleFor(item),
            trailing: MoneyText(
              item.originalAmount,
              currency: currency,
              style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }

  String? _subtitleFor(SubcontractItem item) {
    final parts = [
      if ((costCodeLabels[item.costCodeId] ?? '').isNotEmpty) costCodeLabels[item.costCodeId]!,
      if (item.unit.isNotEmpty && item.quantity != null) '${item.quantity} ${item.unit}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

class _EmptySectionText extends StatelessWidget {
  const _EmptySectionText(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Text(message, style: AppTypography.helper),
    );
  }
}

/// Aktivasyon/tamamlama/iptal/fesih -- yalnızca UX kolaylığı (görünürlük
/// durum+izne göre süzülür), backend HER durumda bağımsız olarak reddeder
/// (bkz. `ProjectService.ActivateSubcontract` vb. -- her biri kendi
/// durum-korumalı SQL'iyle çalışır). "Düzenle" YALNIZCA `draft`ta ve
/// `subcontracts.manage` iznine sahipken görünür; diğer dördü
/// `subcontracts.approve` gerektirir (legacy_user/project_manager bu izne
/// SAHİP DEĞİL -- bkz. backend migration 0038 rol matrisi). "Aktifleştir"/
/// "Tamamla" ileri yönlü aksiyonlar `AppLifecycleActions`ta birincil (gold,
/// tam genişlik) buton olarak işaretlenir -- ikisi asla aynı anda uygun
/// olamaz (farklı durumlara bağlı), geri kalanı ikincil.
class _LifecycleActionsBar extends ConsumerStatefulWidget {
  const _LifecycleActionsBar({
    required this.projectId,
    required this.subcontractId,
    required this.subcontract,
    required this.canManage,
    required this.canApprove,
    required this.onChanged,
  });

  final String projectId;
  final String subcontractId;
  final Subcontract subcontract;
  final bool canManage;
  final bool canApprove;
  final VoidCallback onChanged;

  @override
  ConsumerState<_LifecycleActionsBar> createState() => _LifecycleActionsBarState();
}

class _LifecycleActionsBarState extends ConsumerState<_LifecycleActionsBar> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Onayla')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<String?> _promptReason(String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Gerekçe'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Vazgeç')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Onayla'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(projectsRepositoryProvider);
    final sc = widget.subcontract;
    final actions = <AppLifecycleAction>[];

    if (sc.isEditable && widget.canManage) {
      actions.add(AppLifecycleAction(
        label: 'Düzenle',
        icon: Icons.edit_outlined,
        onPressed: _busy
            ? null
            : () => context.push('/projeler/${widget.projectId}/taseronlar/${widget.subcontractId}/duzenle'),
      ));
    }
    if (sc.canActivate && widget.canApprove) {
      actions.add(AppLifecycleAction(
        label: 'Aktifleştir',
        icon: Icons.play_arrow,
        primary: true,
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm(
                    'Aktifleştir', 'Bu taşeron sözleşmesi aktifleştirilsin mi? Ticari şartlar bundan sonra kilitlenir.');
                if (!ok) return;
                await _run(() => repo.activateSubcontract(widget.projectId, widget.subcontractId));
              },
      ));
    }
    if (sc.canCancel && widget.canApprove) {
      actions.add(AppLifecycleAction(
        label: 'İptal Et',
        icon: Icons.cancel_outlined,
        onPressed: _busy
            ? null
            : () async {
                final reason = await _promptReason('Sözleşmeyi İptal Et');
                if (reason == null || reason.isEmpty) return;
                await _run(() => repo.cancelSubcontract(widget.projectId, widget.subcontractId, reason: reason));
              },
      ));
    }
    if (sc.canComplete && widget.canApprove) {
      actions.add(AppLifecycleAction(
        label: 'Tamamla',
        icon: Icons.check_circle_outline,
        primary: true,
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Tamamla', 'Bu taşeron sözleşmesi tamamlandı olarak işaretlensin mi?');
                if (!ok) return;
                await _run(() => repo.completeSubcontract(widget.projectId, widget.subcontractId));
              },
      ));
    }
    if (sc.canTerminate && widget.canApprove) {
      actions.add(AppLifecycleAction(
        label: 'Feshet',
        icon: Icons.block,
        onPressed: _busy
            ? null
            : () async {
                final reason = await _promptReason('Sözleşmeyi Feshet');
                if (reason == null || reason.isEmpty) return;
                await _run(() => repo.terminateSubcontract(widget.projectId, widget.subcontractId, reason: reason));
              },
      ));
    }

    return AppLifecycleActions(actions: actions);
  }
}
