import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../data/budget_providers.dart';
import '../domain/budget.dart';
import 'sheets/adjustment_sheet.dart';
import 'widgets/budget_ui.dart';

/// Bütçe Revizyonları (web `AdjustmentsSection`): baseline alınmış bütçede
/// kalem bazında revizyon TASLAĞI oluşturma ve taslakları Onayla/Reddet.
/// Yalnızca ONAYLANAN revizyon revize bütçeyi etkiler. Karara bağlanmış bir
/// revizyon tekrar onaylanamaz/reddedilemez (sunucu 409 -> liste tazelenir).
/// Okuma `projects.budget.read`, oluşturma `projects.budget.manage`, karar
/// `projects.budget.approve`. Kişinin kendi revizyonunda (Sahip değilse)
/// düğmeler yerine neden gösterilir -- sunucu zaten 409 ile reddeder; diğer
/// red sebepleri (ör. revize bütçe negatife düşer) sunucu mesajıyla.
class BudgetAdjustmentsScreen extends ConsumerStatefulWidget {
  const BudgetAdjustmentsScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<BudgetAdjustmentsScreen> createState() => _BudgetAdjustmentsScreenState();
}

class _BudgetAdjustmentsScreenState extends ConsumerState<BudgetAdjustmentsScreen> {
  String? _busyId;

  String get _pid => widget.projectId;

  Future<void> _refresh() async {
    invalidateBudgetModule(ref.invalidate, _pid);
    try {
      await ref.read(budgetAdjustmentsProvider(_pid).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _create(List<BudgetLine> lines, String currency) async {
    final saved = await showAdjustmentSheet(context, projectId: _pid, currency: currency, lines: lines);
    if (saved == true) _snack('Revizyon oluşturuldu; onaylandığında revize bütçeye yansır.');
  }

  Future<void> _decide(BudgetAdjustment a, String lineLabel, String currency, {required bool approve}) async {
    final amount = Formatters.signedMoney(a.amount, currency: currency);
    final ok = await confirmBudgetAction(
      context,
      title: approve ? 'Revizyonu Onayla' : 'Revizyonu Reddet',
      message: approve
          ? '"$lineLabel" kalemi için $amount revizyon onaylansın mı? Onaylanan tutar kalemin revize bütçesine yansır.'
          : '"$lineLabel" kalemi için $amount revizyon reddedilsin mi? Reddedilen revizyon bütçeyi etkilemez.',
      confirmLabel: approve ? 'Onayla' : 'Reddet',
      danger: !approve,
    );
    if (!ok || !mounted) return;
    setState(() => _busyId = a.id);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      final repo = ref.read(budgetRepositoryProvider);
      if (approve) {
        await repo.approveAdjustment(_pid, a.id);
      } else {
        await repo.rejectAdjustment(_pid, a.id);
      }
      invalidateBudgetModule(invalidate, _pid);
      _snack(approve ? 'Revizyon onaylandı.' : 'Revizyon reddedildi.');
    } catch (e) {
      // 409: başka biri bu arada karara bağladı -- güncel durum yüklenir.
      if (isBudgetConflict(e)) invalidateBudgetModule(invalidate, _pid);
      _snack(budgetErrorText(e));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    const title = Text('Bütçe Revizyonları');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (isAuthPending(auth)) return AppPageScaffold(title: title, body: const LoadingState());
    if (!user.can(kBudgetReadPermission)) {
      return const AppPageScaffold(
        title: title,
        body: BudgetNoAccessView(message: kBudgetNoAccessText),
      );
    }
    final project = ref.watch(budgetProjectProvider(_pid)).valueOrNull;
    final locked = project != null && isProjectLocked(project.status);
    final hasManage = user.can(kBudgetManagePermission);
    final canManage = hasManage && !locked;
    final hasApprove = user.can(kBudgetApprovePermission);
    final canApprove = hasApprove && !locked;
    // Tek onaylayıcısı olan küçük firma kilitlenmesin: Sahip kendi
    // revizyonuna da karar verebilir (backend ile aynı kural).
    final isOwner = user?.organizationRoleCode == 'owner';
    bool ownBlocked(BudgetAdjustment a) => !isOwner && a.isCreatedBy(user?.id);
    final budgetAsync = ref.watch(projectBudgetProvider(_pid));
    final linesAsync = ref.watch(budgetLinesProvider(_pid));
    final adjAsync = ref.watch(budgetAdjustmentsProvider(_pid));

    final firstError = budgetAsync.error ?? adjAsync.error;
    Widget body;
    if (firstError != null) {
      body = isBudgetForbidden(firstError)
          ? const BudgetNoAccessView(message: kBudgetNoAccessText)
          : ErrorState(error: firstError, onRetry: _refresh);
    } else if (!budgetAsync.hasValue || !adjAsync.hasValue) {
      body = const LoadingState();
    } else {
      final budget = budgetAsync.value;
      final adjustments = adjAsync.value!;
      final lines = linesAsync.valueOrNull ?? const <BudgetLine>[];
      final lineById = {for (final l in lines) l.id: l};
      final currency = budget?.currency ?? project?.currency ?? 'TRY';
      final pending = adjustments.where((a) => a.isPending).length;
      final canCreate = canManage && (budget?.isBaselined ?? false) && lines.isNotEmpty;

      body = RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
          children: [
            if (locked) ...[const ReadOnlyNotice(kProjectLockedText), const SizedBox(height: AppSpacing.md)],
            if (!locked && !hasManage && !hasApprove) ...[
              const ReadOnlyNotice(kBudgetReadOnlyText),
              const SizedBox(height: AppSpacing.md),
            ],
            if (!locked && hasManage && !hasApprove && pending > 0) ...[
              const ReadOnlyNotice(kBudgetApproveMissingText),
              const SizedBox(height: AppSpacing.md),
            ],
            BudgetInfoNote(
              budget != null && budget.isBaselined
                  ? 'Baseline alınmış bütçede kalem tutarları sabittir; her değişiklik bir revizyon olarak kaydedilir '
                        've yalnızca onaylandıktan sonra revize bütçeyi etkiler.'
                  : 'Bütçe revizyonu yalnızca baseline alınmış bir bütçe için oluşturulabilir. Taslak '
                        'bütçede kalemler doğrudan düzenlenir.',
            ),
            if (canCreate) ...[
              const SizedBox(height: AppSpacing.md),
              PrimaryButton(
                label: 'Revizyon Oluştur',
                icon: Icons.add,
                onPressed: _busyId != null ? null : () => _create(lines, currency),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            if (adjustments.isEmpty)
              const EmptyStateView(
                message: 'Henüz bir bütçe revizyonu oluşturulmadı.',
                icon: Icons.published_with_changes_outlined,
              )
            else ...[
              Text(
                pending > 0
                    ? '${adjustments.length} revizyon · $pending onay bekliyor'
                    : '${adjustments.length} revizyon',
                style: AppTypography.metadata,
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final a in adjustments)
                _AdjustmentCard(
                  adjustment: a,
                  lineLabel: lineById[a.budgetLineId]?.description ?? '—',
                  costCodeLabel: lineById[a.budgetLineId]?.costCodeLabel,
                  currency: currency,
                  canDecide: canApprove && a.isPending && !ownBlocked(a),
                  ownPending: canApprove && a.isPending && ownBlocked(a),
                  busy: _busyId == a.id,
                  disabled: _busyId != null,
                  onApprove: () => _decide(a, lineById[a.budgetLineId]?.description ?? '—', currency, approve: true),
                  onReject: () => _decide(a, lineById[a.budgetLineId]?.description ?? '—', currency, approve: false),
                ),
            ],
          ],
        ),
      );
    }

    return AppPageScaffold(title: title, body: body);
  }
}

class _AdjustmentCard extends StatelessWidget {
  const _AdjustmentCard({
    required this.adjustment,
    required this.lineLabel,
    required this.costCodeLabel,
    required this.currency,
    required this.canDecide,
    this.ownPending = false,
    required this.busy,
    required this.disabled,
    required this.onApprove,
    required this.onReject,
  });

  final BudgetAdjustment adjustment;
  final String lineLabel;
  final String? costCodeLabel;
  final String currency;
  final bool canDecide;

  /// Onay izni var ama revizyon kişinin kendisinin: düğme yerine neden.
  final bool ownPending;
  final bool busy;
  final bool disabled;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final a = adjustment;
    final amountColor = a.amount < 0 ? AppColors.danger : AppColors.success;
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lineLabel, style: AppTypography.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (costCodeLabel != null)
                      // 2 satır: "GNL-001 — Şantiye Genel Giderleri" 360 dp'de
                      // tutar sütununun yanında tek satıra sığmıyordu.
                      Text(costCodeLabel!, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    Formatters.signedMoney(a.amount, currency: currency),
                    style: AppTypography.body.copyWith(
                      fontWeight: FontWeight.w700,
                      color: amountColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  StatusRegistry.build(a.status, BudgetStatusRegistry.adjustment),
                ],
              ),
            ],
          ),
          if (a.reason.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(a.reason, style: AppTypography.body.copyWith(height: 1.35)),
          ],
          const SizedBox(height: AppSpacing.xs),
          Text(
            [
              if (a.createdAt.isNotEmpty) 'Oluşturulma: ${Formatters.date(a.createdAt)}',
              if (a.approvedAt != null) 'Karar: ${Formatters.date(a.approvedAt)}',
            ].join(' · '),
            style: AppTypography.helper,
          ),
          if (ownPending) ...[
            const SizedBox(height: AppSpacing.sm),
            const ReadOnlyNotice(kBudgetOwnAdjustmentText),
          ],
          if (canDecide) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                    onPressed: disabled ? null : onReject,
                    child: const Text('Reddet'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: PrimaryButton(label: 'Onayla', loading: busy, onPressed: disabled ? null : onApprove),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
