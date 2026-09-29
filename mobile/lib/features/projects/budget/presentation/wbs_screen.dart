import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../data/budget_providers.dart';
import '../domain/budget.dart';
import 'sheets/wbs_node_sheet.dart';
import 'widgets/budget_ui.dart';

enum _NodeAction { addChild, rename, archive }

/// WBS (İş Kırılım Yapısı) ağacı -- web `WBSTab`: kök/alt düğüm ekle,
/// yeniden adlandır, arşivle (HARD DELETE DEĞİL; bağlı bütçe kalemleri
/// etkilenmez). Arşivlenmiş düğümler soluk ve üstü çizili görünür, aksiyon
/// almaz. Okuma `projects.budget.read`, yazma `projects.budget.manage`.
class WbsScreen extends ConsumerStatefulWidget {
  const WbsScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<WbsScreen> createState() => _WbsScreenState();
}

class _WbsScreenState extends ConsumerState<WbsScreen> {
  bool _busy = false;

  String get _pid => widget.projectId;

  Future<void> _refresh() async {
    ref.invalidate(budgetWbsNodesProvider(_pid));
    try {
      await ref.read(budgetWbsNodesProvider(_pid).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _add({WbsNode? parent}) async {
    final saved = await showWbsNodeSheet(context, projectId: _pid, parent: parent);
    if (saved != null) _snack('WBS düğümü eklendi.');
  }

  Future<void> _rename(WbsNode node) async {
    final saved = await showWbsNodeSheet(context, projectId: _pid, existing: node);
    if (saved != null) _snack('WBS düğümü kaydedildi.');
  }

  Future<void> _archive(WbsNode node) async {
    final ok = await confirmBudgetAction(
      context,
      title: 'WBS Düğümünü Arşivle',
      message:
          '"${node.name}" (${node.code}) arşivlenecek. Bu düğüme bağlı bütçe kalemleri etkilenmez, yalnızca '
          'yeni seçimlerde gizlenir.',
      confirmLabel: 'Arşivle',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(budgetRepositoryProvider).archiveWbsNode(_pid, node.id);
      invalidateBudgetModule(invalidate, _pid);
      _snack('WBS düğümü arşivlendi.');
    } catch (e) {
      if (isBudgetConflict(e)) invalidateBudgetModule(invalidate, _pid);
      _snack(budgetErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const title = Text('WBS (İş Kırılım Yapısı)');
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
    final nodesAsync = ref.watch(budgetWbsNodesProvider(_pid));

    return AppPageScaffold(
      title: title,
      body: nodesAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isBudgetForbidden(e)
            ? const BudgetNoAccessView(message: kBudgetNoAccessText)
            : ErrorState(error: e, onRetry: _refresh),
        data: (nodes) {
          final tree = flattenWbsTree(nodes);
          final archived = nodes.where((n) => !n.isActive).length;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
              children: [
                if (locked) ...[const ReadOnlyNotice(kProjectLockedText), const SizedBox(height: AppSpacing.md)],
                if (!locked && !hasManage) ...[
                  const ReadOnlyNotice(kWbsReadOnlyText),
                  const SizedBox(height: AppSpacing.md),
                ],
                const BudgetInfoNote(
                  'WBS (İş Kırılım Yapısı), bütçe kalemlerini fiziksel/işlevsel gruplara ayırmak içindir — maliyet '
                  'kodlarından (hangi tür maliyet) farklı bir eksendir (bkz. Maliyet Kodları ekranı).',
                ),
                const SizedBox(height: AppSpacing.lg),
                if (canManage) ...[
                  SecondaryButton(label: 'Kök Düğüm Ekle', icon: Icons.add, onPressed: _busy ? null : () => _add()),
                  const SizedBox(height: AppSpacing.md),
                ],
                if (tree.isEmpty)
                  const EmptyStateView(message: 'Henüz bir WBS düğümü yok.', icon: Icons.account_tree_outlined)
                else ...[
                  Text(
                    '${nodes.length - archived} aktif düğüm${archived > 0 ? ' · $archived arşivlendi' : ''}',
                    style: AppTypography.metadata,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppCard(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Column(
                      children: [
                        for (var i = 0; i < tree.length; i++) ...[
                          if (i > 0) const Divider(height: 1, indent: AppSpacing.md, endIndent: AppSpacing.md),
                          _WbsRow(
                            entry: tree[i],
                            canManage: canManage && !_busy,
                            onAction: (action) => switch (action) {
                              _NodeAction.addChild => _add(parent: tree[i].node),
                              _NodeAction.rename => _rename(tree[i].node),
                              _NodeAction.archive => _archive(tree[i].node),
                            },
                          ),
                        ],
                      ],
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

class _WbsRow extends StatelessWidget {
  const _WbsRow({required this.entry, required this.canManage, required this.onAction});

  final WbsTreeEntry entry;
  final bool canManage;
  final ValueChanged<_NodeAction> onAction;

  @override
  Widget build(BuildContext context) {
    final n = entry.node;
    // Derin ağaçta dar ekranda metin sıkışmasın: girinti 4 seviyede sabitlenir.
    final indent = (entry.depth.clamp(0, 4)) * 18.0;
    final muted = !n.isActive;
    final textStyle = AppTypography.body.copyWith(
      color: muted ? AppColors.textMuted : null,
      decoration: muted ? TextDecoration.lineThrough : null,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.md + indent, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
      child: Row(
        children: [
          Icon(
            entry.depth == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_right,
            size: 18,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: n.code,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: ' · ${n.name}'),
                  ],
                ),
                style: textStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (muted) ...[
            const SizedBox(width: AppSpacing.xs),
            const StatusBadge(label: 'Arşivlendi', tone: StatusTone.muted),
            const SizedBox(width: AppSpacing.sm),
          ],
          if (n.isActive && canManage)
            PopupMenuButton<_NodeAction>(
              tooltip: 'Düğüm işlemleri',
              icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
              onSelected: onAction,
              itemBuilder: (_) => const [
                PopupMenuItem(value: _NodeAction.addChild, child: Text('Alt Düğüm Ekle')),
                PopupMenuItem(value: _NodeAction.rename, child: Text('Yeniden Adlandır')),
                PopupMenuItem(
                  value: _NodeAction.archive,
                  child: Text('Arşivle', style: TextStyle(color: AppColors.danger)),
                ),
              ],
            )
          else if (!muted)
            const SizedBox(width: AppSpacing.sm),
        ],
      ),
    );
  }
}
