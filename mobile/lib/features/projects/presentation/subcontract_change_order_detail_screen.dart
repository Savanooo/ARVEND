import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_lifecycle_actions.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/subcontract.dart';

/// Sprint 5 P2 — Taşeron Değişiklik Emri detayı (`subcontract_change_orders`,
/// MALİYET tarafı) -- Sprint-3'ün "Ek İşler" (GELİR tarafı) İLE
/// KARIŞTIRILMAMALI, bkz. domain/subcontract.dart dosya başı notu.
class SubcontractChangeOrderDetailScreen extends ConsumerWidget {
  const SubcontractChangeOrderDetailScreen({
    super.key,
    required this.projectId,
    required this.subcontractId,
    required this.changeOrderId,
  });

  final String projectId;
  final String subcontractId;
  final String changeOrderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, changeOrderId: changeOrderId);
    final detailAsync = ref.watch(subcontractChangeOrderDetailProvider(args));

    return AppPageScaffold(
      title: detailAsync.maybeWhen(
        data: (d) => Text(d.changeOrder.number),
        orElse: () => const Text('Değişiklik Emri'),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(subcontractChangeOrderDetailProvider(args)),
        data: (context, detail) => _ChangeOrderDetailBody(
          projectId: projectId,
          subcontractId: subcontractId,
          changeOrderId: changeOrderId,
          changeOrder: detail.changeOrder,
          items: detail.items,
        ),
      ),
    );
  }
}

class _ChangeOrderDetailBody extends ConsumerWidget {
  const _ChangeOrderDetailBody({
    required this.projectId,
    required this.subcontractId,
    required this.changeOrderId,
    required this.changeOrder,
    required this.items,
  });

  final String projectId;
  final String subcontractId;
  final String changeOrderId;
  final SubcontractChangeOrder changeOrder;
  final List<SubcontractChangeOrderItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontracts.manage');
    final canApprove =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontracts.approve');
    final scArgs = (projectId: projectId, subcontractId: subcontractId);
    final currency = ref.watch(subcontractDetailProvider(scArgs)).valueOrNull?.subcontract.currency ?? 'TRY';

    void refreshAll() {
      final coArgs = (projectId: projectId, changeOrderId: changeOrderId);
      ref.invalidate(subcontractChangeOrderDetailProvider(coArgs));
      ref.invalidate(subcontractChangeOrdersProvider(scArgs));
      // Onay, ana sözleşmenin current_value/commitment'ını değiştirir (bkz.
      // syncSubcontractCommitments) -- sözleşme detayı da tazelenmeli.
      ref.invalidate(subcontractDetailProvider(scArgs));
      ref.invalidate(projectCostControlProvider(projectId));
    }

    final signed = changeOrder.signedAmount;
    final isAddition = changeOrder.changeType == SubcontractChangeOrder.typeAddition;
    final amountColor = isAddition ? AppColors.success : AppColors.danger;

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        changeOrder.title,
                        style: AppTypography.cardTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    StatusRegistry.build(changeOrder.status, StatusRegistry.subcontractChangeOrder),
                  ],
                ),
                if (changeOrder.description.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(changeOrder.description, style: AppTypography.metadata),
                ],
                const SizedBox(height: AppSpacing.md),
                Align(
                  alignment: Alignment.centerRight,
                  // İşaret (+/-) yalnızca GÖRÜNTÜLEME içindir (bkz.
                  // domain/subcontract.dart `signedAmount` yorumu) -- kart
                  // yüzeyi/kenarlığı DEĞİL, yalnızca bu metin renklendirilir.
                  child: Text(
                    '${signed >= 0 ? '+' : ''}${Formatters.money(signed, currency: currency)}',
                    style: AppTypography.metricPrimary.copyWith(color: amountColor),
                  ),
                ),
                const Divider(height: AppSpacing.xl),
                AppDataRow(label: 'Tür', value: isAddition ? 'Ek İş (+)' : 'Kesinti (-)'),
                AppDataRow(label: 'Toplam Tutar', value: Formatters.money(changeOrder.amount, currency: currency)),
                if (changeOrder.reason.isNotEmpty) AppDataRow(label: 'Gerekçe', value: changeOrder.reason),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _ChangeOrderLifecycleActionsBar(
            projectId: projectId,
            subcontractId: subcontractId,
            changeOrderId: changeOrderId,
            changeOrder: changeOrder,
            canManage: canManage,
            canApprove: canApprove,
            onChanged: refreshAll,
          ),
          if (changeOrder.status == SubcontractChangeOrder.statusRejected && changeOrder.rejectionReason.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            AppCard(
              color: AppColors.danger.withValues(alpha: 0.06),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Red Gerekçesi', style: AppTypography.sectionTitle.copyWith(color: AppColors.danger)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(changeOrder.rejectionReason, style: AppTypography.body),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: 'Kalemler'),
          const SizedBox(height: AppSpacing.sm),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text('Kalem yok.', style: AppTypography.metadata),
            )
          else
            ...items.map((it) => AppListCard(
                  title: it.description,
                  trailing: MoneyText(
                    it.amount,
                    currency: currency,
                    style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
                  ),
                )),
        ],
      ),
    );
  }
}

/// Düzenle/Gönder/İptal `subcontracts.manage` -- Onayla/Reddet
/// `subcontracts.approve` (bkz. Phase 1: değişiklik emirlerinin KENDİ izni
/// YOK, ana sözleşmenin manage/approve'unu PAYLAŞIR).
class _ChangeOrderLifecycleActionsBar extends ConsumerStatefulWidget {
  const _ChangeOrderLifecycleActionsBar({
    required this.projectId,
    required this.subcontractId,
    required this.changeOrderId,
    required this.changeOrder,
    required this.canManage,
    required this.canApprove,
    required this.onChanged,
  });

  final String projectId;
  final String subcontractId;
  final String changeOrderId;
  final SubcontractChangeOrder changeOrder;
  final bool canManage;
  final bool canApprove;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ChangeOrderLifecycleActionsBar> createState() => _ChangeOrderLifecycleActionsBarState();
}

class _ChangeOrderLifecycleActionsBarState extends ConsumerState<_ChangeOrderLifecycleActionsBar> {
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
    final co = widget.changeOrder;
    final actions = <AppLifecycleAction>[];

    if (co.canSubmit && widget.canManage) {
      actions.add(AppLifecycleAction(
        label: 'Gönder',
        icon: Icons.send_outlined,
        primary: true,
        loading: _busy,
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Gönder', 'Bu değişiklik emri onay için gönderilsin mi?');
                if (!ok) return;
                await _run(() => repo.submitSubcontractChangeOrder(widget.projectId, widget.changeOrderId));
              },
      ));
    }
    if (co.canApprove && widget.canApprove) {
      actions.add(AppLifecycleAction(
        label: 'Onayla',
        icon: Icons.check_circle_outline,
        primary: true,
        loading: _busy,
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Onayla',
                    'Bu değişiklik emri onaylansın mı? Onay, sözleşmenin güncel değerini ve taahhüt kaydını hemen değiştirir.');
                if (!ok) return;
                await _run(() => repo.approveSubcontractChangeOrder(widget.projectId, widget.changeOrderId));
              },
      ));
    }
    if (co.isEditable && widget.canManage) {
      actions.add(AppLifecycleAction(
        label: 'Düzenle',
        icon: Icons.edit_outlined,
        loading: _busy,
        onPressed: _busy
            ? null
            : () => context.push(
                '/projeler/${widget.projectId}/taseronlar/${widget.subcontractId}/degisiklik-emirleri/${widget.changeOrderId}/duzenle'),
      ));
    }
    if (co.canCancel && widget.canManage) {
      actions.add(AppLifecycleAction(
        label: 'İptal Et',
        icon: Icons.cancel_outlined,
        loading: _busy,
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('İptal Et', 'Bu değişiklik emri iptal edilsin mi?');
                if (!ok) return;
                await _run(() => repo.cancelSubcontractChangeOrder(widget.projectId, widget.changeOrderId));
              },
      ));
    }
    if (co.canReject && widget.canApprove) {
      actions.add(AppLifecycleAction(
        label: 'Reddet',
        icon: Icons.thumb_down_outlined,
        loading: _busy,
        onPressed: _busy
            ? null
            : () async {
                final reason = await _promptReason('Değişiklik Emrini Reddet');
                if (reason == null || reason.isEmpty) return;
                await _run(
                    () => repo.rejectSubcontractChangeOrder(widget.projectId, widget.changeOrderId, reason: reason));
              },
      ));
    }

    return AppLifecycleActions(actions: actions);
  }
}
