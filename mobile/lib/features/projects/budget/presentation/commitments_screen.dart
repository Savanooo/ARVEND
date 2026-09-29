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
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../budget_paths.dart';
import '../data/budget_providers.dart';
import '../domain/budget.dart';
import 'sheets/commitment_sheet.dart';
import 'widgets/budget_ui.dart';

/// Taahhütler (web `CommitmentsTab`): projenin TÜM taahhüt defteri --
/// manuel, satın alma siparişi ve taşeron kaynaklı. "Manuel Taahhüt" ekleme
/// ve manuel taahhüdü iptal etme `projects.cost_control.manage` ister;
/// sipariş/taşeron taahhütleri kendi belgelerinden yönetilir. İptal edilen
/// taahhüt taahhüt toplamından düşer ama geçmişte görünür kalır.
class CommitmentsScreen extends ConsumerStatefulWidget {
  const CommitmentsScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<CommitmentsScreen> createState() => _CommitmentsScreenState();
}

class _CommitmentsScreenState extends ConsumerState<CommitmentsScreen> {
  bool _showVoided = true;

  String get _pid => widget.projectId;

  Future<void> _refresh() async {
    invalidateBudgetModule(ref.invalidate, _pid);
    try {
      await ref.read(budgetCommitmentsProvider(_pid).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _create() async {
    final saved = await context.push<bool>(commitmentCreatePath(_pid));
    if (saved == true) _snack('Manuel taahhüt kaydedildi.');
  }

  Future<void> _open(Commitment c, {required bool canVoid, String? lineLabel}) async {
    final voided = await showCommitmentSheet(
      context,
      projectId: _pid,
      commitment: c,
      canVoid: canVoid,
      budgetLineLabel: lineLabel,
    );
    if (voided == true) _snack('Taahhüt iptal edildi.');
  }

  @override
  Widget build(BuildContext context) {
    const title = Text('Taahhütler');
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
    final commitmentsAsync = ref.watch(budgetCommitmentsProvider(_pid));
    // Bütçe kalemi adları yalnızca bilgi amaçlı (budget.read yoksa istenmez).
    final lines = user.can(kBudgetReadPermission)
        ? (ref.watch(budgetLinesProvider(_pid)).valueOrNull ?? const <BudgetLine>[])
        : const <BudgetLine>[];
    final lineById = {for (final l in lines) l.id: l};

    return AppPageScaffold(
      title: title,
      body: commitmentsAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isBudgetForbidden(e)
            ? const BudgetNoAccessView(message: kCostControlNoAccessText)
            : ErrorState(error: e, onRetry: _refresh),
        data: (all) {
          final active = all.where((c) => c.status == 'active').length;
          final voidedCount = all.length - active;
          final visible = _showVoided ? all : all.where((c) => c.status == 'active').toList();
          return RefreshIndicator(
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
                  'Bu, resmi bir satın alma siparişi veya taşeron sözleşmesi değildir — yalnızca sahada bilinen ama '
                  'henüz masraf olarak girilmemiş bir maliyet taahhüdünü kayıt altına almak içindir. Sipariş ve taşeron '
                  'taahhütleri, belgeleri onaylandığında buraya otomatik düşer.',
                  title: 'Manuel Taahhüt:',
                ),
                if (canManage) ...[
                  const SizedBox(height: AppSpacing.md),
                  PrimaryButton(label: 'Manuel Taahhüt', icon: Icons.add, onPressed: _create),
                ],
                const SizedBox(height: AppSpacing.lg),
                if (all.isEmpty)
                  const EmptyStateView(message: 'Henüz taahhüt yok.', icon: Icons.handshake_outlined)
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$active aktif${voidedCount > 0 ? ' · $voidedCount iptal edildi' : ''}',
                          style: AppTypography.metadata,
                        ),
                      ),
                      if (voidedCount > 0)
                        FilterChip(
                          key: const ValueKey('commitments-show-voided'),
                          label: const Text('İptal edilenler'),
                          selected: _showVoided,
                          onSelected: (v) => setState(() => _showVoided = v),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (final c in visible)
                    _CommitmentCard(
                      commitment: c,
                      onTap: () => _open(
                        c,
                        canVoid: canManage,
                        lineLabel: c.budgetLineId == null ? null : lineById[c.budgetLineId]?.description,
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CommitmentCard extends StatelessWidget {
  const _CommitmentCard({required this.commitment, required this.onTap});

  final Commitment commitment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = commitment;
    final voided = c.status == 'voided' || c.isVoided;
    final muted = voided ? AppColors.textMuted : null;
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  c.description.isEmpty ? '${c.costCodeCode} — ${c.costCodeName}' : c.description,
                  style: AppTypography.cardTitle.copyWith(color: muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                Formatters.money(c.committedAmount, currency: c.currency),
                style: AppTypography.body.copyWith(
                  fontWeight: FontWeight.w700,
                  color: muted,
                  decoration: voided ? TextDecoration.lineThrough : null,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${Formatters.date(c.committedAt)} · ${c.costCodeCode} — ${c.costCodeName}',
            style: AppTypography.metadata,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              StatusBadge(label: commitmentSourceLabel(c.sourceType), tone: StatusTone.muted),
              StatusRegistry.build(c.status, BudgetStatusRegistry.commitment),
              if (c.budgetLineId == null) const StatusBadge(label: 'Bütçe Dışı', tone: StatusTone.warning),
            ],
          ),
          if (voided && c.voidReason.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'İptal: ${c.voidReason}',
              style: AppTypography.helper.copyWith(color: AppColors.danger),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
