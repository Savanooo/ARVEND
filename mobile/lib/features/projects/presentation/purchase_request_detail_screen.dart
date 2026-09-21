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
import '../../../core/widgets/app_lifecycle_actions.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';

/// P3 — Satın Alma Talebi detayı. Artık yalnızca görüntüleme DEĞİL --
/// düzenleme + tam yaşam döngüsü aksiyonları (bkz. `_LifecycleActionsBar`).
class PurchaseRequestDetailScreen extends ConsumerWidget {
  const PurchaseRequestDetailScreen({
    super.key,
    required this.projectId,
    required this.prId,
  });
  final String projectId;
  final String prId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, prId: prId);
    final detailAsync = ref.watch(purchaseRequestDetailProvider(args));

    return AppPageScaffold(
      title: detailAsync.maybeWhen(
        data: (d) => Text(d.request.prNo),
        orElse: () => const Text('Satın Alma Talebi'),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async =>
            ref.invalidate(purchaseRequestDetailProvider(args)),
        data: (context, detail) => _PurchaseRequestDetailBody(
          projectId: projectId,
          prId: prId,
          detail: detail,
        ),
      ),
    );
  }
}

class _PurchaseRequestDetailBody extends ConsumerWidget {
  const _PurchaseRequestDetailBody({
    required this.projectId,
    required this.prId,
    required this.detail,
  });
  final String projectId;
  final String prId;
  final ({PurchaseRequest request, List<PurchaseRequestItem> items}) detail;

  /// "Sonraki Adım" ipucu -- YALNIZCA zaten var olan `canX` getter'larından
  /// türetilir, veride olmayan yeni bir adım/kural İCAT EDİLMEZ (bkz. görev
  /// notu). Onay bekleyen taraf (approve/reject) en öncelikli, ardından
  /// geri çekme, ardından gönderme -- bunlar birbirini dışlar çünkü hepsi
  /// farklı `status` değerlerine bağlıdır.
  String? _nextStepHint(PurchaseRequest pr, {required bool canManage, required bool canApprove}) {
    if (pr.canApprove && canApprove) {
      return 'Bu talep onayınızı bekliyor. Onaylayabilir veya reddedebilirsiniz.';
    }
    if (pr.canWithdraw && canManage) {
      return 'Talep onay için gönderildi ve onaylayıcıyı bekliyor. Geri çekerseniz tekrar düzenleyebilirsiniz.';
    }
    if (pr.canSubmit && canManage) {
      return 'Talep taslak durumda. Gönderildiğinde onaya sunulur.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, prId: prId);
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('projects.procurement.manage');
    final canApprove =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('projects.procurement.approve');

    void refreshAll() {
      ref.invalidate(purchaseRequestDetailProvider(args));
      ref.invalidate(projectPurchaseRequestsProvider(projectId));
    }

    final pr = detail.request;
    final nextStepHint = _nextStepHint(pr, canManage: canManage, canApprove: canApprove);
    final hasApprovalHistory = pr.submittedAt != null ||
        pr.approvedAt != null ||
        pr.rejectedAt != null ||
        pr.cancelledAt != null;

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(pr.status, StatusRegistry.purchaseRequest),
              MoneyText(
                pr.estimatedTotal,
                style: AppTypography.metricPrimary,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _LifecycleActionsBar(
            projectId: projectId,
            prId: prId,
            request: pr,
            canManage: canManage,
            canApprove: canApprove,
            onChanged: refreshAll,
          ),
          const SizedBox(height: AppSpacing.lg),

          const AppSectionHeader(title: 'Talep'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pr.title, style: AppTypography.cardTitle),
                if (pr.description.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(pr.description, style: AppTypography.body),
                ],
                const Divider(height: AppSpacing.xl),
                AppDataRow(label: 'İhtiyaç Tarihi', value: Formatters.date(pr.neededBy)),
                AppDataRow(label: 'Oluşturulma', value: Formatters.dateTime(pr.createdAt)),
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: 'Kalemler'),
          if (detail.items.isEmpty)
            const EmptyStateView(message: 'Kalem yok.', icon: Icons.inventory_2_outlined)
          else
            ...detail.items.map((item) => _PurchaseRequestItemTile(item: item)),

          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: 'Onay Durumu'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasApprovalHistory) ...[
                  if (pr.submittedAt != null)
                    AppDataRow(label: 'Gönderilme', value: Formatters.dateTime(pr.submittedAt)),
                  if (pr.approvedAt != null)
                    AppDataRow(label: 'Onaylanma', value: Formatters.dateTime(pr.approvedAt)),
                  if (pr.rejectedAt != null)
                    AppDataRow(label: 'Reddedilme', value: Formatters.dateTime(pr.rejectedAt)),
                  if (pr.cancelledAt != null)
                    AppDataRow(label: 'İptal', value: Formatters.dateTime(pr.cancelledAt)),
                ] else
                  Text('Henüz bir onay işlemi yok.', style: AppTypography.helper),
                if (pr.rejectionReason.isNotEmpty) ...[
                  const Divider(height: AppSpacing.xl),
                  Text('Red Gerekçesi', style: AppTypography.metadata),
                  const SizedBox(height: AppSpacing.xs),
                  Text(pr.rejectionReason, style: AppTypography.body),
                ],
                if (pr.cancelReason.isNotEmpty) ...[
                  const Divider(height: AppSpacing.xl),
                  Text('İptal Gerekçesi', style: AppTypography.metadata),
                  const SizedBox(height: AppSpacing.xs),
                  Text(pr.cancelReason, style: AppTypography.body),
                ],
              ],
            ),
          ),

          if (nextStepHint != null) ...[
            const SizedBox(height: AppSpacing.xl),
            const AppSectionHeader(title: 'Sonraki Adım'),
            AppCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 18, color: AppStatusColors.info),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(nextStepHint, style: AppTypography.body)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Düzenle/Gönder/Geri Çek/İptal `procurement.manage` -- Onayla/Reddet
/// `procurement.approve` (bkz. Phase 1: İptal PR'da `manage` grubunda,
/// PO'nun aksine).
class _LifecycleActionsBar extends ConsumerStatefulWidget {
  const _LifecycleActionsBar({
    required this.projectId,
    required this.prId,
    required this.request,
    required this.canManage,
    required this.canApprove,
    required this.onChanged,
  });

  final String projectId;
  final String prId;
  final PurchaseRequest request;
  final bool canManage;
  final bool canApprove;
  final VoidCallback onChanged;

  @override
  ConsumerState<_LifecycleActionsBar> createState() =>
      _LifecycleActionsBarState();
}

class _LifecycleActionsBarState extends ConsumerState<_LifecycleActionsBar> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Onayla'),
          ),
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Vazgeç'),
          ),
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
    final pr = widget.request;
    final actions = <AppLifecycleAction>[];

    if (pr.isEditable && widget.canManage) {
      actions.add(
        AppLifecycleAction(
          label: 'Düzenle',
          icon: Icons.edit_outlined,
          onPressed: _busy
              ? null
              : () => context.push(
                  '/projeler/${widget.projectId}/satin-alma/talepler/${widget.prId}/duzenle',
                ),
        ),
      );
    }
    if (pr.canSubmit && widget.canManage) {
      actions.add(
        AppLifecycleAction(
          label: 'Gönder',
          icon: Icons.send_outlined,
          primary: true,
          onPressed: _busy
              ? null
              : () async {
                  final ok = await _confirm(
                    'Gönder',
                    'Bu talep onay için gönderilsin mi?',
                  );
                  if (!ok) return;
                  await _run(
                    () => repo.submitPurchaseRequest(
                      widget.projectId,
                      widget.prId,
                    ),
                  );
                },
        ),
      );
    }
    if (pr.canWithdraw && widget.canManage) {
      actions.add(
        AppLifecycleAction(
          label: 'Geri Çek',
          icon: Icons.undo,
          onPressed: _busy
              ? null
              : () async {
                  final ok = await _confirm(
                    'Geri Çek',
                    'Bu talep taslağa geri çekilsin mi? Düzenlemeye devam edebilirsiniz.',
                  );
                  if (!ok) return;
                  await _run(
                    () => repo.withdrawPurchaseRequest(
                      widget.projectId,
                      widget.prId,
                    ),
                  );
                },
        ),
      );
    }
    if (pr.canApprove && widget.canApprove) {
      actions.add(
        AppLifecycleAction(
          label: 'Onayla',
          icon: Icons.check_circle_outline,
          primary: true,
          onPressed: _busy
              ? null
              : () async {
                  final ok = await _confirm(
                    'Onayla',
                    'Bu talep onaylansın mı?',
                  );
                  if (!ok) return;
                  await _run(
                    () => repo.approvePurchaseRequest(
                      widget.projectId,
                      widget.prId,
                    ),
                  );
                },
        ),
      );
    }
    if (pr.canReject && widget.canApprove) {
      actions.add(
        AppLifecycleAction(
          label: 'Reddet',
          icon: Icons.thumb_down_outlined,
          onPressed: _busy
              ? null
              : () async {
                  final reason = await _promptReason('Talebi Reddet');
                  if (reason == null || reason.isEmpty) return;
                  await _run(
                    () => repo.rejectPurchaseRequest(
                      widget.projectId,
                      widget.prId,
                      reason: reason,
                    ),
                  );
                },
        ),
      );
    }
    if (pr.canCancel && widget.canManage) {
      actions.add(
        AppLifecycleAction(
          label: 'İptal Et',
          icon: Icons.cancel_outlined,
          onPressed: _busy
              ? null
              : () async {
                  final reason = await _promptReason('Talebi İptal Et');
                  if (reason == null || reason.isEmpty) return;
                  await _run(
                    () => repo.cancelPurchaseRequest(
                      widget.projectId,
                      widget.prId,
                      reason: reason,
                    ),
                  );
                },
        ),
      );
    }

    return AppLifecycleActions(actions: actions);
  }
}

class _PurchaseRequestItemTile extends StatelessWidget {
  const _PurchaseRequestItemTile({required this.item});
  final PurchaseRequestItem item;

  @override
  Widget build(BuildContext context) {
    return AppListCard(
      title: item.description,
      subtitle: '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)} ${item.unit}'
          '${item.estimatedUnitCost != null ? '  ×  ${Formatters.money(item.estimatedUnitCost!)}' : ''}',
      trailing: MoneyText(
        item.estimatedTotal,
        style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
