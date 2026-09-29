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
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/money_text.dart';
import '../../../../core/widgets/status_badge.dart';
import '../budget_paths.dart';
import '../data/budget_providers.dart';
import '../domain/budget.dart';
import 'sheets/adjustment_sheet.dart';
import 'widgets/budget_ui.dart';

/// Bütçe (web "Bütçe" sekmesinin bütçe bölümü): bütçe yoksa "Bütçe Oluştur";
/// TASLAK'ta kalem ekle/düzenle/sil + "Baseline Al" (tek yönlü, onaylı);
/// BASELINE sonrası kalem tutarları sabittir, değişiklik "Revize Et" ile
/// revizyon taslağı olarak girilir. Okuma `projects.budget.read`, tüm
/// yazmalar `projects.budget.manage`; tamamlanan/iptal projede yazma yok.
class BudgetScreen extends ConsumerStatefulWidget {
  const BudgetScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends ConsumerState<BudgetScreen> {
  bool _busy = false;

  String get _pid => widget.projectId;

  Future<void> _refresh() async {
    invalidateBudgetModule(ref.invalidate, _pid);
    try {
      await ref.read(projectBudgetProvider(_pid).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Ortak yazma akışı: hata metni snackbar'da; 409'da (başka biri durumu
  /// değiştirdi) ekran sunucudaki güncel duruma tazelenir.
  Future<bool> _run(Future<void> Function() action, {required String success}) async {
    setState(() => _busy = true);
    // Kapsayıcı ilk await'ten ÖNCE: istek sürerken geri basılıp ekran
    // kapansa da alttaki Maliyet Kontrolü görünümü tazelenir.
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await action();
      invalidateBudgetModule(invalidate, _pid);
      _snack(success);
      return true;
    } catch (e) {
      if (isBudgetConflict(e)) invalidateBudgetModule(invalidate, _pid);
      _snack(budgetErrorText(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createBudget() =>
      _run(() => ref.read(budgetRepositoryProvider).createBudget(_pid), success: 'Bütçe oluşturuldu.');

  Future<void> _baseline() async {
    final ok = await confirmBudgetAction(
      context,
      title: 'Bütçeyi Baseline Al',
      message:
          'Baseline alındıktan sonra kalemlerin orijinal tutarları KALICI olarak sabitlenir — bundan sonraki her '
          'değişiklik bir "Bütçe Revizyonu" olarak kaydedilmelidir. Bu işlem GERİ ALINAMAZ.',
      confirmLabel: 'Baseline Al',
      danger: true,
    );
    if (!ok) return;
    await _run(() => ref.read(budgetRepositoryProvider).baselineBudget(_pid), success: 'Bütçe baseline alındı.');
  }

  Future<void> _deleteLine(BudgetLine line) async {
    final ok = await confirmBudgetAction(
      context,
      title: 'Bütçe Kalemini Sil',
      message: '"${line.description}" kalemi silinecek.',
      confirmLabel: 'Sil',
      danger: true,
    );
    if (!ok) return;
    await _run(() => ref.read(budgetRepositoryProvider).deleteBudgetLine(_pid, line.id), success: 'Kalem silindi.');
  }

  Future<void> _openLineForm({BudgetLine? line}) async {
    final saved = await context.push<bool>(
      line == null ? budgetLineCreatePath(_pid) : budgetLineEditPath(_pid, line.id),
    );
    if (saved == true) _snack('Bütçe kalemi kaydedildi.');
  }

  Future<void> _adjust(BudgetLine line, String currency) async {
    final saved = await showAdjustmentSheet(
      context,
      projectId: _pid,
      currency: currency,
      initialLineId: line.id,
      initialLineLabel: line.description,
    );
    if (saved == true) _snack('Revizyon oluşturuldu; onaylandığında revize bütçeye yansır.');
  }

  @override
  Widget build(BuildContext context) {
    const title = Text('Bütçe');
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
    final canManage = user.can(kBudgetManagePermission) && !locked;
    final budgetAsync = ref.watch(projectBudgetProvider(_pid));

    return AppPageScaffold(
      title: title,
      body: budgetAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isBudgetForbidden(e)
            ? const BudgetNoAccessView(message: kBudgetNoAccessText)
            : ErrorState(error: e, onRetry: _refresh),
        data: (budget) {
          final currency = budget?.currency ?? project?.currency ?? 'TRY';
          return RefreshIndicator(
            onRefresh: _refresh,
            child: budget == null
                ? _NoBudgetView(
                    canCreate: canManage,
                    busy: _busy,
                    locked: locked,
                    readOnly: !user.can(kBudgetManagePermission),
                    onCreate: _createBudget,
                  )
                : _BudgetBody(
                    projectId: _pid,
                    budget: budget,
                    currency: currency,
                    canManage: canManage,
                    locked: locked,
                    readOnly: !user.can(kBudgetManagePermission),
                    busy: _busy,
                    onAddLine: () => _openLineForm(),
                    onEditLine: (l) => _openLineForm(line: l),
                    onDeleteLine: _deleteLine,
                    onAdjustLine: (l) => _adjust(l, currency),
                    onBaseline: _baseline,
                    onRetryLines: _refresh,
                  ),
          );
        },
      ),
    );
  }
}

class _NoBudgetView extends StatelessWidget {
  const _NoBudgetView({
    required this.canCreate,
    required this.busy,
    required this.locked,
    required this.readOnly,
    required this.onCreate,
  });

  final bool canCreate;
  final bool busy;
  final bool locked;
  final bool readOnly;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (locked) ...[const ReadOnlyNotice(kProjectLockedText), const SizedBox(height: AppSpacing.md)],
        if (!locked && readOnly) ...[const ReadOnlyNotice(kBudgetReadOnlyText), const SizedBox(height: AppSpacing.md)],
        AppCard(
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: AppColors.gold.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: const Icon(Icons.account_balance_wallet_outlined, color: AppColors.gold),
              ),
              const SizedBox(height: AppSpacing.md),
              const Text(
                'Bu proje için henüz bir bütçe yok',
                style: AppTypography.sectionTitle,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xs),
              const Text(
                'Bütçe oluşturduktan sonra kalem ekleyebilir, baseline alabilir ve revizyon yönetebilirsin.',
                style: AppTypography.metadata,
                textAlign: TextAlign.center,
              ),
              if (canCreate) ...[
                const SizedBox(height: AppSpacing.lg),
                PrimaryButton(label: 'Bütçe Oluştur', icon: Icons.add, loading: busy, onPressed: onCreate),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BudgetBody extends ConsumerWidget {
  const _BudgetBody({
    required this.projectId,
    required this.budget,
    required this.currency,
    required this.canManage,
    required this.locked,
    required this.readOnly,
    required this.busy,
    required this.onAddLine,
    required this.onEditLine,
    required this.onDeleteLine,
    required this.onAdjustLine,
    required this.onBaseline,
    required this.onRetryLines,
  });

  final String projectId;
  final ProjectBudget budget;
  final String currency;
  final bool canManage;
  final bool locked;
  final bool readOnly;
  final bool busy;
  final VoidCallback onAddLine;
  final ValueChanged<BudgetLine> onEditLine;
  final ValueChanged<BudgetLine> onDeleteLine;
  final ValueChanged<BudgetLine> onAdjustLine;
  final VoidCallback onBaseline;
  final Future<void> Function() onRetryLines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linesAsync = ref.watch(budgetLinesProvider(projectId));
    final lines = linesAsync.valueOrNull ?? const <BudgetLine>[];
    final pending = budget.isBaselined
        ? (ref.watch(budgetAdjustmentsProvider(projectId)).valueOrNull ?? const []).where((a) => a.isPending).length
        : 0;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        if (locked) ...[const ReadOnlyNotice(kProjectLockedText), const SizedBox(height: AppSpacing.md)],
        if (!locked && readOnly) ...[const ReadOnlyNotice(kBudgetReadOnlyText), const SizedBox(height: AppSpacing.md)],
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  StatusRegistry.build(budget.status, BudgetStatusRegistry.budget),
                  const Spacer(),
                  Text(budget.currency, style: AppTypography.metadata),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                budget.isDraft
                    ? 'Taslak — kalemler serbestçe düzenlenebilir.'
                    : 'Baseline alındı — kalem tutarları sabit, değişiklikler Bütçe Revizyonu ile yapılır.',
                style: AppTypography.body,
              ),
              if (budget.isBaselined && budget.baselinedAt != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text('Baseline tarihi: ${Formatters.date(budget.baselinedAt)}', style: AppTypography.helper),
              ],
              if (budget.isDraft && canManage) ...[
                const SizedBox(height: AppSpacing.lg),
                SecondaryButton(label: 'Kalem Ekle', icon: Icons.add, onPressed: busy ? null : onAddLine),
                const SizedBox(height: AppSpacing.sm),
                PrimaryButton(
                  label: 'Baseline Al',
                  icon: Icons.lock_outline,
                  loading: busy,
                  onPressed: lines.isEmpty ? null : onBaseline,
                ),
                if (lines.isEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  const Text('Baseline almak için en az bir kalem ekle.', style: AppTypography.helper),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        AppSectionHeader(
          title: 'Bütçe Kalemleri',
          trailing: lines.isEmpty ? null : Text('${lines.length} kalem', style: AppTypography.metadata),
        ),
        const SizedBox(height: AppSpacing.sm),
        linesAsync.when(
          loading: () => const Padding(padding: EdgeInsets.all(AppSpacing.xl), child: LoadingState()),
          error: (e, _) => BudgetSectionError(error: e, onRetry: onRetryLines, forbiddenText: kBudgetNoAccessText),
          data: (lines) => lines.isEmpty
              ? EmptyStateView(
                  message: budget.isDraft && canManage
                      ? 'Henüz bütçe kalemi yok. Yukarıdan yeni bir kalem ekle.'
                      : 'Henüz bütçe kalemi yok.',
                )
              : Column(
                  children: [
                    for (final l in lines)
                      _BudgetLineCard(
                        line: l,
                        currency: currency,
                        actions: [
                          if (budget.isDraft && canManage) ...[
                            _LineAction('Düzenle', Icons.edit_outlined, () => onEditLine(l)),
                            _LineAction('Sil', Icons.delete_outline, () => onDeleteLine(l), danger: true),
                          ],
                          if (budget.isBaselined && canManage)
                            _LineAction('Revize Et', Icons.published_with_changes_outlined, () => onAdjustLine(l)),
                        ],
                        busy: busy,
                      ),
                  ],
                ),
        ),
        if (budget.isBaselined) ...[
          const SizedBox(height: AppSpacing.lg),
          BudgetNavCard(
            icon: Icons.published_with_changes_outlined,
            title: 'Bütçe Revizyonları',
            // Bekleyen sayısı yalnızca rozette; alt metin tekrar etmez (360 dp'de
            // kesiliyordu).
            subtitle: 'Onaylanan ve bekleyen revizyonlar',
            badge: pending > 0 ? StatusBadge(label: '$pending bekliyor', tone: StatusTone.warning) : null,
            onTap: () => context.push(budgetAdjustmentsPath(projectId)),
          ),
        ],
      ],
    );
  }
}

class _LineAction {
  const _LineAction(this.label, this.icon, this.onPressed, {this.danger = false});

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool danger;
}

class _BudgetLineCard extends StatelessWidget {
  const _BudgetLineCard({required this.line, required this.currency, required this.actions, required this.busy});

  final BudgetLine line;
  final String currency;
  final List<_LineAction> actions;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final qty = l.quantity;
    final unitCost = l.unitCost;
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  l.description,
                  style: AppTypography.cardTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              MoneyText(
                l.originalAmount,
                currency: currency,
                style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(l.costCodeLabel, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (l.wbsCode.isNotEmpty)
            Text(
              'WBS: ${l.wbsCode}${l.wbsName.isEmpty ? '' : ' — ${l.wbsName}'}',
              style: AppTypography.helper,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (qty != null && unitCost != null)
            Text(
              '${formatBudgetQuantity(qty)}${l.unit.isEmpty ? '' : ' ${l.unit}'} × ${Formatters.money(unitCost, currency: currency)}',
              style: AppTypography.helper,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (l.notes.isNotEmpty)
            Text(l.notes, style: AppTypography.helper, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (actions.isNotEmpty) ...[
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpacing.xs,
              children: [
                for (final a in actions)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: a.danger ? AppColors.danger : null,
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: busy ? null : a.onPressed,
                    icon: Icon(a.icon, size: 18),
                    label: Text(a.label),
                  ),
              ],
            ),
          ] else
            const SizedBox(height: AppSpacing.xs),
        ],
      ),
    );
  }
}
