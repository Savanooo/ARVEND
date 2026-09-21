import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/quick_action_button.dart';
import '../../../core/widgets/status_badge.dart';
import '../../auth/domain/user.dart';
import '../../tasks/domain/task_filters.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';
import 'collection_form_sheet.dart';
import 'expense_form_sheet.dart';
import 'note_form_sheet.dart';

/// RBAC/Project Membership sprint'i: gruplar kullanıcının izin kümesine
/// göre GİZLENİR (spec: "no finance section shown without finance
/// permission") -- bu YALNIZCA UX'tir, gerçek sınır zaten backend'de (bu
/// grup gösterilse bile ilgili uç 403 döner). owner/admin/legacy_user
/// TÜM izinlere sahip olduğu için onlar için hiçbir grup gizlenmez.
///
/// Redesign: eskiden 10 EŞİT AĞIRLIKLI sekme tek bir TabBar'daydı (bkz. git
/// geçmişi) -- şimdi 4 üst-seviye gruba (Özet/Finans/Operasyon/Dokümanlar)
/// toplanıyor, her biri KENDİ içinde (Satın Alma sekmesinin zaten kanıtlanmış
/// `SegmentedButton` deseniyle) alt-görünümler arasında geçer. Aktivite artık
/// birincil bir sekme DEĞİL, AppBar'daki bir simge üzerinden açılan ayrı bir
/// ekran. Her alt-sekmenin İÇERİK widget'ı (ör. `_FinanceTab`, `_FilesTab`)
/// DEĞİŞMEDEN aynen yeniden kullanılıyor -- yalnızca gezinme kabuğu değişti.
class _GroupDef {
  const _GroupDef(this.label, this.visible, this.builder);
  final String label;
  final bool Function(User? user) visible;
  final Widget Function(String projectId, Project project) builder;
}

bool _failOpen(User? user, String permission) =>
    user == null || user.permissions.isEmpty || user.hasPermission(permission);

final _groupDefs = <_GroupDef>[
  _GroupDef('Özet', (user) => true, (id, p) => _OverviewTab(projectId: id, project: p)),
  _GroupDef(
    'Finans',
    (user) => _failOpen(user, 'projects.finance.read') || _failOpen(user, 'projects.cost_control.read'),
    (id, p) => _FinansGroupTab(projectId: id, project: p),
  ),
  _GroupDef(
    'Operasyon',
    (user) =>
        _failOpen(user, 'projects.subcontracts.read') ||
        _failOpen(user, 'projects.procurement.read') ||
        _failOpen(user, 'projects.tasks.read'),
    (id, p) => _OperasyonGroupTab(projectId: id),
  ),
  _GroupDef(
    'Dokümanlar',
    (user) => _failOpen(user, 'projects.operations.read'),
    (id, p) => _DokumanlarGroupTab(projectId: id),
  ),
];

class ProjectDetailScreen extends ConsumerWidget {
  const ProjectDetailScreen({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(projectDetailProvider(projectId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final visibleGroups = _groupDefs.where((g) => g.visible(user)).toList();

    return DefaultTabController(
      length: visibleGroups.length,
      child: AppPageScaffold(
        title: projectAsync.maybeWhen(
          data: (p) => Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          orElse: () => const Text('Proje'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Proje Hareketleri',
            onPressed: () => _openActivity(context, projectId),
          ),
        ],
        bottom: TabBar(
          isScrollable: true,
          tabs: [for (final g in visibleGroups) Tab(text: g.label)],
        ),
        body: AsyncStateView(
          value: projectAsync,
          onRetry: () async => ref.invalidate(projectDetailProvider(projectId)),
          data: (context, project) => TabBarView(
            children: [for (final g in visibleGroups) g.builder(projectId, project)],
          ),
        ),
      ),
    );
  }
}

/// Aktivite artık birincil bir sekme DEĞİL -- hem AppBar simgesinden hem
/// Özet'in alt bağlantısından AYNI tam-ekrana açılır, tek yerde tanımlı.
void _openActivity(BuildContext context, String projectId) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => AppPageScaffold(
      title: const Text('Proje Hareketleri'),
      body: _ActivityTab(projectId: projectId),
    ),
  ));
}

/// "Özet" -- yeni iniş sekmesi. Proje/müşteri bilgisi + birincil finansal
/// özet (varsa) + hızlı işlemler + diğer 3 gruba giden gezinme kartları.
/// Aşağıdaki hiçbir alt-widget (`_FinanceTab`, `_FilesTab` vb.) burada
/// YENİDEN yazılmadı -- yalnızca onlara giden yol kısaltıldı.
class _OverviewTab extends ConsumerWidget {
  const _OverviewTab({required this.projectId, required this.project});
  final String projectId;
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final visibleGroups = _groupDefs.where((g) => g.visible(user)).toList();

    void goToGroup(String label) {
      final index = visibleGroups.indexWhere((g) => g.label == label);
      if (index >= 0) DefaultTabController.of(context).animateTo(index);
    }

    final canFinance = _failOpen(user, 'projects.finance.read');
    final canCreateTask = _failOpen(user, 'projects.tasks.create');
    final canManageFiles = _failOpen(user, 'projects.operations.manage');
    final canSeeCostControl = _failOpen(user, 'projects.cost_control.read');

    final summaryAsync = canFinance ? ref.watch(projectFinancialSummaryProvider(projectId)) : null;
    final costControlAsync = canFinance && canSeeCostControl ? ref.watch(projectCostControlProvider(projectId)) : null;

    Future<void> addExpense() async {
      final created = await showExpenseFormSheet(context, projectId, currency: project.currency);
      if (created != null) {
        ref.invalidate(projectExpensesProvider(projectId));
        ref.invalidate(projectFinancialSummaryProvider(projectId));
        if (canSeeCostControl) ref.invalidate(projectCostControlProvider(projectId));
      }
    }

    Future<void> addCollection() async {
      final created = await showCollectionFormSheet(context, projectId, currency: project.currency);
      if (created != null) {
        ref.invalidate(projectCollectionsProvider(projectId));
        ref.invalidate(projectFinancialSummaryProvider(projectId));
        if (canSeeCostControl) ref.invalidate(projectCostControlProvider(projectId));
      }
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(project.projectNo, style: AppTypography.cardTitle),
                  ),
                  StatusRegistry.build(project.status, StatusRegistry.project),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _InfoRow(label: 'Proje Türü', value: project.projectType.isEmpty ? '-' : project.projectType),
              _InfoRow(
                  label: 'Sözleşme Tutarı',
                  value: Formatters.money(project.contractAmount, currency: project.currency)),
              _InfoRow(label: 'Başlangıç', value: Formatters.date(project.startDate)),
              _InfoRow(label: 'Bitiş', value: Formatters.date(project.endDate)),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Müşteri Bilgileri', style: AppTypography.cardTitle),
              const SizedBox(height: AppSpacing.sm),
              _InfoRow(label: 'Ad', value: project.customerName.isEmpty ? '-' : project.customerName),
              _InfoRow(label: 'Telefon', value: project.customerPhone.isEmpty ? '-' : project.customerPhone),
              _InfoRow(label: 'E-posta', value: project.customerEmail.isEmpty ? '-' : project.customerEmail),
            ],
          ),
        ),
        if (project.description.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Açıklama', style: AppTypography.cardTitle),
                const SizedBox(height: AppSpacing.sm),
                Text(project.description, style: AppTypography.body),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        const AppSectionHeader(title: 'Hızlı İşlemler'),
        const SizedBox(height: AppSpacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              if (canFinance)
                QuickActionButton(icon: Icons.receipt_long_outlined, label: 'Masraf Ekle', onPressed: addExpense),
              if (canFinance) ...[
                const SizedBox(width: AppSpacing.sm),
                QuickActionButton(
                    icon: Icons.payments_outlined, label: 'Tahsilat Ekle', onPressed: addCollection),
              ],
              if (canCreateTask) ...[
                const SizedBox(width: AppSpacing.sm),
                QuickActionButton(
                  icon: Icons.checklist_outlined,
                  label: 'Görev Ekle',
                  onPressed: () => context.push('/projeler/$projectId/gorevler/yeni'),
                ),
              ],
              if (canManageFiles) ...[
                const SizedBox(width: AppSpacing.sm),
                QuickActionButton(
                  icon: Icons.photo_camera_outlined,
                  label: 'Fotoğraf Ekle',
                  onPressed: () => goToGroup('Dokümanlar'),
                ),
              ],
            ],
          ),
        ),
        if (summaryAsync != null) ...[
          const SizedBox(height: AppSpacing.lg),
          const AppSectionHeader(title: 'Finansal Özet'),
          const SizedBox(height: AppSpacing.sm),
          AsyncStateView(
            value: summaryAsync,
            onRetry: () async => ref.invalidate(projectFinancialSummaryProvider(projectId)),
            data: (context, s) => _FinancialSummaryCard(summary: s, costControl: costControlAsync?.valueOrNull),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        const AppSectionHeader(title: 'Proje Alanları'),
        const SizedBox(height: AppSpacing.sm),
        for (final group in visibleGroups.where((g) => g.label != 'Özet'))
          _GroupNavCard(
            label: group.label,
            subtitle: switch (group.label) {
              'Finans' => 'Tahsilat, masraf, maliyet kontrolü ve kârlılık',
              'Operasyon' => 'Taşeronlar, satın alma ve görevler',
              'Dokümanlar' => 'Dosyalar, fotoğraflar ve notlar',
              _ => '',
            },
            icon: switch (group.label) {
              'Finans' => Icons.account_balance_wallet_outlined,
              'Operasyon' => Icons.engineering_outlined,
              'Dokümanlar' => Icons.folder_outlined,
              _ => Icons.circle_outlined,
            },
            onTap: () => goToGroup(group.label),
          ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          onTap: () => _openActivity(context, projectId),
          child: Row(
            children: [
              const Icon(Icons.history, color: AppColors.textMuted, size: 20),
              const SizedBox(width: AppSpacing.md),
              const Expanded(child: Text('Tüm proje hareketlerini görüntüle', style: AppTypography.body)),
              const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ],
    );
  }
}

class _GroupNavCard extends StatelessWidget {
  const _GroupNavCard({required this.label, required this.subtitle, required this.icon, required this.onTap});
  final String label;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.gold.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, color: AppColors.gold, size: 20),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTypography.cardTitle),
                Text(subtitle, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}

enum _FinansView { finans, ekIsler, maliyetKontrolu }

/// "Finans" grubu -- Finans/Ek İşler/Maliyet Kontrolü arasında geçer.
/// Her alt-görünüm İZNİNE göre ayrı ayrı gizlenir (Maliyet Kontrolü
/// `projects.cost_control.read`, diğer ikisi `projects.finance.read`) --
/// grubun kendisi görünürse bile alt-sekmelerden biri gizli kalabilir.
class _FinansGroupTab extends ConsumerStatefulWidget {
  const _FinansGroupTab({required this.projectId, required this.project});
  final String projectId;
  final Project project;

  @override
  ConsumerState<_FinansGroupTab> createState() => _FinansGroupTabState();
}

class _FinansGroupTabState extends ConsumerState<_FinansGroupTab> {
  _FinansView? _view;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canFinance = _failOpen(user, 'projects.finance.read');
    final canCostControl = _failOpen(user, 'projects.cost_control.read');

    final segments = [
      if (canFinance) const ButtonSegment(value: _FinansView.finans, label: Text('Finans')),
      if (canFinance) const ButtonSegment(value: _FinansView.ekIsler, label: Text('Ek İşler')),
      if (canCostControl) const ButtonSegment(value: _FinansView.maliyetKontrolu, label: Text('Maliyet Kontrolü')),
    ];
    _view ??= segments.isEmpty ? null : segments.first.value;
    if (_view == null) return const SizedBox.shrink();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: SegmentedButton<_FinansView>(
            segments: segments,
            selected: {_view!},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
        ),
        Expanded(
          child: switch (_view!) {
            _FinansView.finans => _FinanceTab(projectId: widget.projectId, project: widget.project),
            _FinansView.ekIsler => _ChangeOrdersTab(projectId: widget.projectId),
            _FinansView.maliyetKontrolu => _CostControlTab(projectId: widget.projectId, project: widget.project),
          },
        ),
      ],
    );
  }
}

enum _OperasyonView { taseronlar, satinAlma, gorevler }

/// "Operasyon" grubu -- Taşeronlar/Satın Alma/Görevler arasında geçer.
class _OperasyonGroupTab extends ConsumerStatefulWidget {
  const _OperasyonGroupTab({required this.projectId});
  final String projectId;

  @override
  ConsumerState<_OperasyonGroupTab> createState() => _OperasyonGroupTabState();
}

class _OperasyonGroupTabState extends ConsumerState<_OperasyonGroupTab> {
  _OperasyonView? _view;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final segments = [
      if (_failOpen(user, 'projects.subcontracts.read'))
        const ButtonSegment(value: _OperasyonView.taseronlar, label: Text('Taşeronlar')),
      if (_failOpen(user, 'projects.procurement.read'))
        const ButtonSegment(value: _OperasyonView.satinAlma, label: Text('Satın Alma')),
      if (_failOpen(user, 'projects.tasks.read'))
        const ButtonSegment(value: _OperasyonView.gorevler, label: Text('Görevler')),
    ];
    _view ??= segments.isEmpty ? null : segments.first.value;
    if (_view == null) return const SizedBox.shrink();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: SegmentedButton<_OperasyonView>(
            segments: segments,
            selected: {_view!},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
        ),
        Expanded(
          child: switch (_view!) {
            _OperasyonView.taseronlar => _SubcontractsTab(projectId: widget.projectId),
            _OperasyonView.satinAlma => _ProcurementTab(projectId: widget.projectId),
            _OperasyonView.gorevler => _OperationsTab(projectId: widget.projectId),
          },
        ),
      ],
    );
  }
}

enum _DokumanlarView { dosyalar, notlar }

/// "Dokümanlar" grubu -- Dosyalar/Notlar arasında geçer. İkisi de AYNI
/// izni (`projects.operations.read`) paylaştığı için alt-segment listesi
/// hiçbir zaman boş kalmaz (grup zaten bu izne göre gizlendi).
class _DokumanlarGroupTab extends StatefulWidget {
  const _DokumanlarGroupTab({required this.projectId});
  final String projectId;

  @override
  State<_DokumanlarGroupTab> createState() => _DokumanlarGroupTabState();
}

class _DokumanlarGroupTabState extends State<_DokumanlarGroupTab> {
  _DokumanlarView _view = _DokumanlarView.dosyalar;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: SegmentedButton<_DokumanlarView>(
            segments: const [
              ButtonSegment(value: _DokumanlarView.dosyalar, label: Text('Dosyalar')),
              ButtonSegment(value: _DokumanlarView.notlar, label: Text('Notlar')),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
        ),
        Expanded(
          child: switch (_view) {
            _DokumanlarView.dosyalar => _FilesTab(projectId: widget.projectId),
            _DokumanlarView.notlar => _NotesTab(projectId: widget.projectId),
          },
        ),
      ],
    );
  }
}

class _FinanceTab extends ConsumerWidget {
  const _FinanceTab({required this.projectId, required this.project});
  final String projectId;
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(projectFinancialSummaryProvider(projectId));
    final expensesAsync = ref.watch(projectExpensesProvider(projectId));
    final collectionsAsync = ref.watch(projectCollectionsProvider(projectId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    // Maliyet Kontrolü (bütçe bazlı EAC/tahmini kâr) AYRI bir izin
    // (projects.cost_control.read) -- Finans sekmesini görebilen her
    // kullanıcı bunu göremeyebilir; izin yoksa özet kartı yalnızca
    // financial-summary'nin HER ZAMAN dolu olan taahhüt-bazlı tahminine
    // (committed_cost/estimated_gross_profit) düşer, gereksiz 403 isteği
    // atılmaz.
    final canSeeCostControl = user == null || user.permissions.isEmpty || user.hasPermission('projects.cost_control.read');
    final costControlAsync = canSeeCostControl ? ref.watch(projectCostControlProvider(projectId)) : null;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(projectFinancialSummaryProvider(projectId));
        ref.invalidate(projectExpensesProvider(projectId));
        ref.invalidate(projectCollectionsProvider(projectId));
        if (canSeeCostControl) ref.invalidate(projectCostControlProvider(projectId));
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AsyncStateView(
            value: summaryAsync,
            onRetry: () async => ref.invalidate(projectFinancialSummaryProvider(projectId)),
            data: (context, s) => _FinancialSummaryCard(summary: s, costControl: costControlAsync?.valueOrNull),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(child: Text('Masraflar', style: TextStyle(fontWeight: FontWeight.w700))),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Masraf Ekle'),
                onPressed: () async {
                  final created = await showExpenseFormSheet(context, projectId, currency: project.currency);
                  if (created != null) {
                    ref.invalidate(projectExpensesProvider(projectId));
                    ref.invalidate(projectFinancialSummaryProvider(projectId));
                    if (canSeeCostControl) ref.invalidate(projectCostControlProvider(projectId));
                  }
                },
              ),
            ],
          ),
          AsyncStateView(
            value: expensesAsync,
            onRetry: () async => ref.invalidate(projectExpensesProvider(projectId)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: EmptyStateView(message: 'Henüz masraf kaydı yok.'),
            ),
            data: (context, expenses) => Column(
              children: expenses
                  .map((e) => Card(
                        margin: const EdgeInsets.only(top: 8),
                        child: ListTile(
                          title: Text(expenseCategories[e.category] ?? e.category),
                          subtitle: Text(
                            [e.description, if (e.supplierName.isNotEmpty) e.supplierName].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            Formatters.money(e.amount, currency: e.currency.isEmpty ? project.currency : e.currency),
                            style: TextStyle(
                              decoration: e.isVoided ? TextDecoration.lineThrough : null,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(child: Text('Tahsilatlar', style: TextStyle(fontWeight: FontWeight.w700))),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Tahsilat Ekle'),
                onPressed: () async {
                  final created = await showCollectionFormSheet(context, projectId, currency: project.currency);
                  if (created != null) {
                    ref.invalidate(projectCollectionsProvider(projectId));
                    ref.invalidate(projectFinancialSummaryProvider(projectId));
                    if (canSeeCostControl) ref.invalidate(projectCostControlProvider(projectId));
                  }
                },
              ),
            ],
          ),
          AsyncStateView(
            value: collectionsAsync,
            onRetry: () async => ref.invalidate(projectCollectionsProvider(projectId)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: EmptyStateView(message: 'Henüz tahsilat kaydı yok.'),
            ),
            data: (context, collections) => Column(
              children: collections
                  .map((c) => Card(
                        margin: const EdgeInsets.only(top: 8),
                        child: ListTile(
                          title: Text(
                            c.paymentMethod.isEmpty ? 'Tahsilat' : c.paymentMethod,
                          ),
                          subtitle: Text(
                            [
                              Formatters.date(c.receivedDate),
                              if (c.description.isNotEmpty) c.description,
                              if (c.referenceNo.isNotEmpty) c.referenceNo,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            Formatters.money(c.amount, currency: c.currency.isEmpty ? project.currency : c.currency),
                            style: TextStyle(
                              decoration: c.isVoided ? TextDecoration.lineThrough : null,
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade700,
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Adım 1 (birleşik kârlılık özeti) — Finans sekmesinin tepesindeki tek
/// Özet kartı, `financial-summary` (HER ZAMAN dolu) ile `cost-control`'ün
/// bütçe-bazlı EAC/tahmini kâr rakamlarını (izin varsa VE bütçe oluşmuşsa)
/// YAN YANA gösterir -- gerçekleşen/tahmini AYRI bloklarda kalır, TEK bir
/// yanıltıcı rakamda birleştirilmez (bkz. iş isteği). Backend'in hesapladığı
/// hiçbir rakam burada YENİDEN hesaplanmaz.
class _FinancialSummaryCard extends StatelessWidget {
  const _FinancialSummaryCard({required this.summary, required this.costControl});
  final FinancialSummary summary;
  final ({CostControlSummary summary, List<CostControlLine> lines})? costControl;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final cc = costControl?.summary;
    final hasForecastBudget = cc != null && cc.hasBudget;
    // Bütçe varsa EAC/tahmini-kâr/marj bütçe-bazlı (cost-control) kaynaktan;
    // yoksa financial-summary'nin HER ZAMAN dolu olan taahhüt-bazlı
    // (legacy taşeron ödemesi + gider) tahmininden -- iki kaynak asla
    // TOPLANMAZ, yalnızca biri seçilir.
    final forecastCost = hasForecastBudget ? cc.eac : s.committedCost;
    final forecastProfit = hasForecastBudget ? cc.forecastProfit : s.estimatedGrossProfit;
    final forecastMargin = hasForecastBudget ? cc.forecastMarginPercent : s.estimatedMarginPercent;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Özet', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            _InfoRow(
              label: 'Satış / Sözleşme Bedeli',
              value: Formatters.money(s.currentContractValue, currency: s.currency),
              emphasize: true,
            ),
            _InfoRow(label: 'Tahsil Edilen', value: Formatters.money(s.collectedAmount, currency: s.currency)),
            _InfoRow(label: 'Kalan Alacak', value: Formatters.money(s.remainingReceivable, currency: s.currency)),
            const Divider(height: 24),
            const Text('Gerçekleşen', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            _InfoRow(label: 'Gerçekleşen Maliyet', value: Formatters.money(s.realizedCost, currency: s.currency)),
            _InfoRow(
              label: 'Gerçekleşen Kâr',
              value: Formatters.money(s.realizedGrossProfit, currency: s.currency),
              valueColor: s.realizedGrossProfit < 0 ? Colors.red : Colors.green,
            ),
            _InfoRow(label: 'Gerçekleşen Marj', value: '%${s.realizedMarginPercent.toStringAsFixed(2)}'),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Flexible(
                  child: Text('Tahmini / Öngörülen',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.grey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    hasForecastBudget ? 'bütçeye göre (EAC)' : 'taahhüt bazlı',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _InfoRow(label: 'Tahmini Maliyet', value: Formatters.money(forecastCost, currency: s.currency)),
            _InfoRow(
              label: 'Tahmini Kâr',
              value: Formatters.money(forecastProfit, currency: s.currency),
              valueColor: forecastProfit < 0 ? Colors.red : Colors.green,
            ),
            _InfoRow(label: 'Tahmini Marj', value: '%${forecastMargin.toStringAsFixed(2)}'),
          ],
        ),
      ),
    );
  }
}

/// Sprint 2 — Maliyet Kontrolü, mobilde YALNIZCA OKUMA (spec: web-first,
/// bu sprintte mobilde düzenleme/onay/taahhüt/tahmin yoktur). Backend
/// hesapları (revised/committed/actual/etc/eac/variance/forecast_profit/
/// forecast_margin) OTORİTER kabul edilir — burada HİÇBİR türetilmiş
/// rakam yeniden hesaplanmaz.
class _CostControlTab extends ConsumerWidget {
  const _CostControlTab({required this.projectId, required this.project});
  final String projectId;
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final costControlAsync = ref.watch(projectCostControlProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectCostControlProvider(projectId)),
      child: AsyncStateView(
        value: costControlAsync,
        onRetry: () async => ref.invalidate(projectCostControlProvider(projectId)),
        data: (context, data) {
          final s = data.summary;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!s.hasBudget)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Bu proje için henüz bir bütçe oluşturulmadı. Bütçe, web uygulamasından oluşturulabilir.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InfoRow(
                          label: 'Sözleşme Bedeli',
                          value: Formatters.money(s.contractValue, currency: s.currency),
                          emphasize: true),
                      _InfoRow(label: 'Revize Bütçe', value: Formatters.money(s.revisedBudget, currency: s.currency)),
                      const Divider(height: 20),
                      _InfoRow(label: 'Taahhüt', value: Formatters.money(s.committedCost, currency: s.currency)),
                      _InfoRow(label: 'Gerçekleşen', value: Formatters.money(s.actualCost, currency: s.currency)),
                      _InfoRow(label: 'EAC (Tahmini Nihai Maliyet)', value: Formatters.money(s.eac, currency: s.currency)),
                      _InfoRow(
                        label: 'Varyans',
                        value: Formatters.money(s.variance, currency: s.currency),
                        valueColor: s.variance < 0 ? Colors.red : Colors.green,
                      ),
                      const Divider(height: 20),
                      _InfoRow(
                        label: 'Tahmini Kâr',
                        value: Formatters.money(s.forecastProfit, currency: s.currency),
                        emphasize: true,
                        valueColor: s.forecastProfit < 0 ? Colors.red : Colors.green,
                      ),
                      _InfoRow(label: 'Tahmini Marj', value: '%${s.forecastMarginPercent.toStringAsFixed(2)}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (data.lines.isNotEmpty) ...[
                const Text('Bütçe Kalemleri', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ...data.lines.map((l) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text('${l.costCodeCode} — ${l.costCodeName}'),
                        subtitle: Text(
                          [
                            if (l.wbsCode.isNotEmpty) l.wbsCode,
                            l.description,
                            if (l.isUnbudgeted) 'Bütçe Dışı',
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(Formatters.money(l.eac, currency: s.currency),
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(
                              Formatters.money(l.variance, currency: s.currency),
                              style: TextStyle(
                                fontSize: 12,
                                color: l.variance < 0 ? Colors.red : Colors.green,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
              ] else if (s.hasBudget)
                const EmptyStateView(message: 'Henüz bütçe kalemi yok.'),
            ],
          );
        },
      ),
    );
  }
}

class _ChangeOrdersTab extends ConsumerWidget {
  const _ChangeOrdersTab({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changeOrdersAsync = ref.watch(projectChangeOrdersProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectChangeOrdersProvider(projectId)),
      child: AsyncStateView(
        value: changeOrdersAsync,
        onRetry: () async => ref.invalidate(projectChangeOrdersProvider(projectId)),
        isEmpty: (list) => list.isEmpty,
        emptyBuilder: (_) => const EmptyStateView(message: 'Henüz ek iş/değişiklik emri yok.'),
        data: (context, changeOrders) => ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: changeOrders.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final co = changeOrders[i];
            final signedTotal = co.changeType == 'deduction' ? -co.grandTotal : co.grandTotal;
            return Card(
              child: ListTile(
                title: Text('${co.changeOrderNo} — ${co.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: StatusRegistry.build(co.status, StatusRegistry.changeOrder),
                trailing: Text(
                  '${signedTotal >= 0 ? '+' : ''}${Formatters.money(signedTotal, currency: co.currency)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: co.changeType == 'addition' ? Colors.green : Colors.red,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Sprint 5 follow-up — Taşeron listesi, tıklanınca detay ekranına
/// (`SubcontractDetailScreen`) gider -- SOV/hakediş/ödeme kaydı ORADA.
class _SubcontractsTab extends ConsumerWidget {
  const _SubcontractsTab({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subcontractsAsync = ref.watch(projectSubcontractsProvider(projectId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canCreate =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontracts.manage');

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectSubcontractsProvider(projectId)),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(child: Text('Taşeron Sözleşmeleri', style: TextStyle(fontWeight: FontWeight.w700))),
              if (canCreate)
                IconButton(
                  onPressed: () => context.push('/projeler/$projectId/taseronlar/yeni'),
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'Taşeron Sözleşmesi Ekle',
                ),
            ],
          ),
          const SizedBox(height: 12),
          AsyncStateView(
            value: subcontractsAsync,
            onRetry: () async => ref.invalidate(projectSubcontractsProvider(projectId)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const EmptyStateView(message: 'Henüz taşeron sözleşmesi yok.'),
            data: (context, subcontracts) => Column(
              children: subcontracts
                  .map((sc) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text('${sc.subcontractNo} — ${sc.supplierName ?? sc.supplierCode ?? ''}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: StatusRegistry.build(sc.status, StatusRegistry.subcontract),
                          trailing: Text(Formatters.money(sc.originalAmount, currency: sc.currency),
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          onTap: () => context.push('/projeler/$projectId/taseronlar/${sc.id}'),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

enum _ProcurementView { requests, rfqs, orders }

/// P3 — Satın Alma. Talep -> RFQ -> Teklif -> Karşılaştırma -> Ödül ->
/// Sipariş zincirinin TÜMÜ artık mobilde -- RFQ/teklif/karşılaştırma/ödül
/// bu sekmenin altında, kendi detay ekranlarında yaşar (bkz.
/// `rfq_detail_screen.dart`). "Ekle" butonları `projects.procurement.
/// manage` iznine göre gizlenir -- gerçek sınır HER ZAMAN backend'dedir.
class _ProcurementTab extends ConsumerStatefulWidget {
  const _ProcurementTab({required this.projectId});
  final String projectId;

  @override
  ConsumerState<_ProcurementTab> createState() => _ProcurementTabState();
}

class _ProcurementTabState extends ConsumerState<_ProcurementTab> {
  _ProcurementView _view = _ProcurementView.requests;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('projects.procurement.manage');

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentedButton<_ProcurementView>(
            segments: const [
              ButtonSegment(value: _ProcurementView.requests, label: Text('Talepler')),
              ButtonSegment(value: _ProcurementView.rfqs, label: Text('RFQ\'lar')),
              ButtonSegment(value: _ProcurementView.orders, label: Text('Siparişler')),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
        ),
        Expanded(
          child: switch (_view) {
            _ProcurementView.requests => _PurchaseRequestsList(projectId: widget.projectId, canManage: canManage),
            _ProcurementView.rfqs => _RFQsList(projectId: widget.projectId, canManage: canManage),
            _ProcurementView.orders => _PurchaseOrdersList(projectId: widget.projectId, canManage: canManage),
          },
        ),
      ],
    );
  }
}

class _PurchaseRequestsList extends ConsumerWidget {
  const _PurchaseRequestsList({required this.projectId, required this.canManage});
  final String projectId;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestsAsync = ref.watch(projectPurchaseRequestsProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectPurchaseRequestsProvider(projectId)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (canManage)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Talep Ekle'),
                onPressed: () => context.push('/projeler/$projectId/satin-alma/talepler/yeni'),
              ),
            ),
          AsyncStateView(
            value: requestsAsync,
            onRetry: () async => ref.invalidate(projectPurchaseRequestsProvider(projectId)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const EmptyStateView(message: 'Henüz satın alma talebi yok.'),
            data: (context, requests) => Column(
              children: requests
                  .map((pr) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text('${pr.prNo} — ${pr.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: StatusRegistry.build(pr.status, StatusRegistry.purchaseRequest),
                          trailing:
                              Text(Formatters.money(pr.estimatedTotal), style: const TextStyle(fontWeight: FontWeight.w700)),
                          onTap: () => context.push('/projeler/$projectId/satin-alma/talepler/${pr.id}'),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _RFQsList extends ConsumerWidget {
  const _RFQsList({required this.projectId, required this.canManage});
  final String projectId;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rfqsAsync = ref.watch(projectRFQsProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectRFQsProvider(projectId)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (canManage)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('RFQ Ekle'),
                onPressed: () => context.push('/projeler/$projectId/satin-alma/rfqlar/yeni'),
              ),
            ),
          AsyncStateView(
            value: rfqsAsync,
            onRetry: () async => ref.invalidate(projectRFQsProvider(projectId)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const EmptyStateView(message: 'Henüz RFQ yok.'),
            data: (context, rfqs) => Column(
              children: rfqs
                  .map((r) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text('${r.rfqNo} — ${r.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: StatusRegistry.build(r.status, StatusRegistry.rfq),
                          trailing: r.isAwarded
                              ? const Icon(Icons.emoji_events_outlined, color: AppColors.gold)
                              : null,
                          onTap: () => context.push('/projeler/$projectId/satin-alma/rfqlar/${r.id}'),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _PurchaseOrdersList extends ConsumerWidget {
  const _PurchaseOrdersList({required this.projectId, required this.canManage});
  final String projectId;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ordersAsync = ref.watch(projectPurchaseOrdersProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectPurchaseOrdersProvider(projectId)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (canManage)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Sipariş Ekle'),
                onPressed: () => context.push('/projeler/$projectId/satin-alma/siparisler/yeni'),
              ),
            ),
          AsyncStateView(
            value: ordersAsync,
            onRetry: () async => ref.invalidate(projectPurchaseOrdersProvider(projectId)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const EmptyStateView(message: 'Henüz satın alma siparişi yok.'),
            data: (context, orders) => Column(
              children: orders
                  .map((po) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text('${po.poNo} — ${po.supplierName ?? po.supplierCode ?? ''}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: StatusRegistry.build(po.status, StatusRegistry.purchaseOrder),
                          trailing: Text(Formatters.money(po.total, currency: po.currency),
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          onTap: () => context.push('/projeler/$projectId/satin-alma/siparisler/${po.id}'),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Faz 7 — Proje görev listesi. `ListTasks`'ın hiçbir sunucu-taraflı filtre
/// parametresi YOK (bkz. Phase 1) -- bu yüzden durum/gecikme filtreleri
/// BURADA istemci tarafında, ZATEN çekilmiş TEK listenin üzerinde
/// uygulanır (yeni bir ağ isteği İCAT EDİLMEZ). Özet şerit `GET
/// /operations-summary`den gelir (Faz 7'den beri var olan, mobilde daha
/// önce hiç tüketilmemiş bir uç).
class _OperationsTab extends ConsumerStatefulWidget {
  const _OperationsTab({required this.projectId});
  final String projectId;

  @override
  ConsumerState<_OperationsTab> createState() => _OperationsTabState();
}

class _OperationsTabState extends ConsumerState<_OperationsTab> {
  TaskStatusFilter _filter = TaskStatusFilter.open;
  bool _overdueOnly = false;

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(projectTasksProvider(widget.projectId));
    final summaryAsync = ref.watch(projectOperationsSummaryProvider(widget.projectId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canCreate = user == null || user.permissions.isEmpty || user.hasPermission('projects.tasks.create');

    void refreshAll() {
      ref.invalidate(projectTasksProvider(widget.projectId));
      ref.invalidate(projectOperationsSummaryProvider(widget.projectId));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          summaryAsync.maybeWhen(
            data: (s) => _SummaryHeader(summary: s),
            orElse: () => const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(child: Text('Görevler', style: TextStyle(fontWeight: FontWeight.w700))),
              if (canCreate)
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Görev Ekle'),
                  onPressed: () => context.push('/projeler/${widget.projectId}/gorevler/yeni'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<TaskStatusFilter>(
                segments: const [
                  ButtonSegment(value: TaskStatusFilter.open, label: Text('Açık')),
                  ButtonSegment(value: TaskStatusFilter.all, label: Text('Tümü')),
                  ButtonSegment(value: TaskStatusFilter.completed, label: Text('Tamamlanan')),
                ],
                selected: {_filter},
                onSelectionChanged: (s) => setState(() => _filter = s.first),
              ),
              FilterChip(
                label: const Text('Yalnızca gecikmiş'),
                selected: _overdueOnly,
                onSelected: (v) => setState(() => _overdueOnly = v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AsyncStateView(
            value: tasksAsync,
            onRetry: () async => ref.invalidate(projectTasksProvider(widget.projectId)),
            data: (context, allTasks) {
              final tasks = allTasks
                  .where((t) => taskMatchesCommonFilters(t, overdueOnly: _overdueOnly) && taskMatchesStatusFilter(t, _filter))
                  .toList();
              if (tasks.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('Bu filtreye uyan görev yok.', style: TextStyle(color: Colors.grey))),
                );
              }
              return Column(
                children: tasks
                    .map((t) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            onTap: () => context.push('/projeler/${widget.projectId}/gorevler/${t.id}'),
                            leading: Checkbox(
                              value: t.status == ProjectTask.statusCompleted,
                              onChanged: t.status == ProjectTask.statusCompleted
                                  ? null
                                  : (_) async {
                                      await ref.read(projectsRepositoryProvider).completeTask(widget.projectId, t.id);
                                      refreshAll();
                                    },
                            ),
                            title: Text(
                              t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.status == ProjectTask.statusCompleted
                                  ? const TextStyle(decoration: TextDecoration.lineThrough)
                                  : null,
                            ),
                            subtitle: Text([
                              if (t.assignedName.isNotEmpty) t.assignedName,
                              if (t.dueDate != null) Formatters.date(t.dueDate),
                            ].join(' · ')),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                StatusRegistry.build(t.status, StatusRegistry.task),
                                if (t.isOverdue)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 4),
                                    child: Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                                  ),
                              ],
                            ),
                          ),
                        ))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.summary});
  final ProjectOperationsSummary summary;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            _StatCell('Açık', '${summary.openTaskCount}'),
            _StatCell('Tamamlanan', '${summary.completedTaskCount}'),
            _StatCell('Gecikmiş', '${summary.overdueTaskCount}', danger: summary.overdueTaskCount > 0),
            _StatCell('Ekip', '${summary.activeMemberCount}'),
          ],
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell(this.label, this.value, {this.danger = false});
  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: danger ? AppColors.danger : null)),
          Text(label, style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
        ],
      ),
    );
  }
}

class _FilesTab extends ConsumerStatefulWidget {
  const _FilesTab({required this.projectId});
  final String projectId;

  @override
  ConsumerState<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<_FilesTab> {
  String get projectId => widget.projectId;
  bool _uploading = false;
  String? _openingFileId;

  bool get _canManage {
    final user = ref.read(authControllerProvider).valueOrNull;
    return user == null || user.permissions.isEmpty || user.hasPermission('projects.operations.manage');
  }

  Future<void> _pickAndUploadPhoto(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (picked == null) return;
    final file = File(picked.path);
    final size = await file.length();
    if (exceedsMaxUploadBytes(size, AppConfig.maxUploadBytes)) {
      _showError('Fotoğraf 25 MiB sınırını aşıyor (${(size / 1024 / 1024).toStringAsFixed(1)} MB).');
      return;
    }
    final meta = await _promptPhotoMeta();
    if (meta == null) return;
    setState(() => _uploading = true);
    try {
      await ref.read(projectsRepositoryProvider).uploadPhoto(
            projectId,
            filePath: picked.path,
            fileName: picked.name,
            stage: meta.stage,
            description: meta.description,
          );
      ref.invalidate(projectPhotosProvider(projectId));
    } on ApiException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickAndUploadFile() async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    final picked = result?.files.single;
    if (picked == null || picked.path == null) return;
    if (exceedsMaxUploadBytes(picked.size, AppConfig.maxUploadBytes)) {
      _showError('Dosya 25 MiB sınırını aşıyor (${(picked.size / 1024 / 1024).toStringAsFixed(1)} MB).');
      return;
    }
    final meta = await _promptFileMeta();
    if (meta == null) return;
    setState(() => _uploading = true);
    try {
      await ref.read(projectsRepositoryProvider).uploadFile(
            projectId,
            filePath: picked.path!,
            fileName: picked.name,
            category: meta.category,
            description: meta.description,
          );
      ref.invalidate(projectFilesProvider(projectId));
    } on ApiException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<({String stage, String description})?> _promptPhotoMeta() {
    var stage = 'progress';
    final descController = TextEditingController();
    return showDialog<({String stage, String description})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Fotoğraf Bilgisi'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                children: kPhotoStages
                    .map((s) => ChoiceChip(
                          label: Text(StatusRegistry.photoStage[s]!.$1),
                          selected: stage == s,
                          onSelected: (_) => setDialogState(() => stage = s),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Vazgeç')),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop((stage: stage, description: descController.text.trim())),
              child: const Text('Yükle'),
            ),
          ],
        ),
      ),
    );
  }

  Future<({String category, String description})?> _promptFileMeta() {
    var category = 'other';
    final descController = TextEditingController();
    return showDialog<({String category, String description})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Dosya Bilgisi'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: kFileCategories
                    .map((c) => ChoiceChip(
                          label: Text(StatusRegistry.fileCategory[c]!.$1),
                          selected: category == c,
                          onSelected: (_) => setDialogState(() => category = c),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Vazgeç')),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop((category: category, description: descController.text.trim())),
              child: const Text('Yükle'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Sil')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _deletePhoto(ProjectPhoto photo) async {
    if (!await _confirm('Fotoğrafı Sil', 'Bu fotoğraf silinsin mi?')) return;
    try {
      await ref.read(projectsRepositoryProvider).deletePhoto(projectId, photo.id);
      ref.invalidate(projectPhotosProvider(projectId));
    } on ApiException catch (e) {
      _showError(e.message);
    }
  }

  Future<void> _deleteFile(ProjectFile file) async {
    if (!await _confirm('Dosyayı Sil', '${file.originalName} silinsin mi?')) return;
    try {
      await ref.read(projectsRepositoryProvider).deleteFile(projectId, file.id);
      ref.invalidate(projectFilesProvider(projectId));
    } on ApiException catch (e) {
      _showError(e.message);
    }
  }

  Future<void> _openPhotoViewer(ProjectPhoto photo) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PhotoViewerScreen(projectId: projectId, photo: photo, canManage: _canManage),
    ));
  }

  /// Bayt indirilip geçici dizine yazılır, ardından OS'un kendi
  /// görüntüleyicisiyle açılır (`open_filex`) -- `Image.network` sorununda
  /// olduğu gibi, kimlik doğrulaması gerektiren bir uçtan `url_launcher`
  /// ile doğrudan bir `file://`/uzak URL açmaya ÇALIŞILMAZ.
  Future<void> _openFile(ProjectFile file) async {
    setState(() => _openingFileId = file.id);
    try {
      final bytes = await ref.read(projectsRepositoryProvider).fileBytes(projectId, file.id);
      final dir = await getTemporaryDirectory();
      final safeName = file.originalName.trim().isEmpty ? file.id : file.originalName.trim();
      final localFile = File('${dir.path}/$safeName');
      await localFile.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      final result = await OpenFilex.open(localFile.path);
      if (result.type != ResultType.done) {
        _showError('Dosya açılamadı: ${result.message}');
      }
    } on ApiException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) setState(() => _openingFileId = null);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final photosAsync = ref.watch(projectPhotosProvider(projectId));
    final filesAsync = ref.watch(projectFilesProvider(projectId));
    final canManage = _canManage;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(projectPhotosProvider(projectId));
        ref.invalidate(projectFilesProvider(projectId));
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_uploading) const LinearProgressIndicator(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(child: Text('Şantiye Fotoğrafları', style: TextStyle(fontWeight: FontWeight.w700))),
              if (canManage)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.photo_camera_outlined),
                      tooltip: 'Kameradan çek',
                      onPressed: _uploading ? null : () => _pickAndUploadPhoto(ImageSource.camera),
                    ),
                    IconButton(
                      icon: const Icon(Icons.photo_library_outlined),
                      tooltip: 'Galeriden seç',
                      onPressed: _uploading ? null : () => _pickAndUploadPhoto(ImageSource.gallery),
                    ),
                  ],
                ),
            ],
          ),
          AsyncStateView(
            value: photosAsync,
            isEmpty: (l) => l.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Fotoğraf yok.', style: TextStyle(color: Colors.grey)),
            ),
            data: (context, photos) => SizedBox(
              height: 90,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: photos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final photo = photos[i];
                  final bytesAsync = ref.watch(projectPhotoBytesProvider((projectId: projectId, photoId: photo.id)));
                  return GestureDetector(
                    onTap: () => _openPhotoViewer(photo),
                    onLongPress: canManage ? () => _deletePhoto(photo) : null,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: bytesAsync.when(
                        data: (bytes) => Image.memory(bytes, width: 90, height: 90, fit: BoxFit.cover),
                        loading: () => Container(
                          width: 90,
                          height: 90,
                          color: Colors.grey.shade200,
                          child: const Center(
                            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                        ),
                        error: (e, st) => Container(
                          width: 90,
                          height: 90,
                          color: Colors.grey.shade200,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Dosyalar', style: TextStyle(fontWeight: FontWeight.w700)),
              if (canManage)
                IconButton(
                  icon: const Icon(Icons.upload_file_outlined),
                  tooltip: 'Dosya yükle',
                  onPressed: _uploading ? null : _pickAndUploadFile,
                ),
            ],
          ),
          AsyncStateView(
            value: filesAsync,
            isEmpty: (l) => l.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Dosya yok.', style: TextStyle(color: Colors.grey)),
            ),
            data: (context, files) => Column(
              children: files
                  .map((f) => Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          leading: _openingFileId == f.id
                              ? const SizedBox(
                                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                              : const Icon(Icons.insert_drive_file_outlined),
                          title: Text(f.originalName, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${Formatters.date(f.createdAt)} · ${(f.sizeBytes / 1024).toStringAsFixed(0)} KB'),
                          onTap: _openingFileId != null ? null : () => _openFile(f),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StatusRegistry.build(f.category, StatusRegistry.fileCategory),
                              if (canManage)
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 20),
                                  onPressed: () => _deleteFile(f),
                                ),
                            ],
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoViewerScreen extends ConsumerWidget {
  const _PhotoViewerScreen({required this.projectId, required this.photo, required this.canManage});
  final String projectId;
  final ProjectPhoto photo;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytesAsync = ref.watch(projectPhotoBytesProvider((projectId: projectId, photoId: photo.id)));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          photo.description.isEmpty ? photo.originalName : photo.description,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          if (canManage)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Fotoğrafı Sil'),
                    content: const Text('Bu fotoğraf silinsin mi?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
                      TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Sil')),
                    ],
                  ),
                );
                if (ok != true) return;
                try {
                  await ref.read(projectsRepositoryProvider).deletePhoto(projectId, photo.id);
                  ref.invalidate(projectPhotosProvider(projectId));
                  if (context.mounted) Navigator.of(context).pop();
                } on ApiException catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
                  }
                }
              },
            ),
        ],
      ),
      body: Center(
        child: bytesAsync.when(
          data: (bytes) => InteractiveViewer(child: Image.memory(bytes)),
          loading: () => const CircularProgressIndicator(color: Colors.white),
          error: (e, st) => const Icon(Icons.broken_image_outlined, color: Colors.white, size: 48),
        ),
      ),
    );
  }
}

class _ActivityTab extends ConsumerWidget {
  const _ActivityTab({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder(
      future: ref.read(projectsRepositoryProvider).events(projectId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final events = snapshot.data ?? [];
        if (events.isEmpty) return const EmptyStateView(message: 'Aktivite kaydı yok.');
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: events.length,
          separatorBuilder: (_, _) => const Divider(),
          itemBuilder: (context, i) {
            final e = events[i];
            return ListTile(
              dense: true,
              title: Text(e['event_type'] as String? ?? ''),
              subtitle: Text(Formatters.dateTime(e['created_at'] as String?)),
            );
          },
        );
      },
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.emphasize = false, this.valueColor});
  final String label;
  final String value;
  final bool emphasize;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            flex: 2,
            child: Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
                fontSize: emphasize ? 16 : 13,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class _NotesTab extends ConsumerWidget {
  const _NotesTab({required this.projectId});
  final String projectId;

  Future<void> _addNote(BuildContext context, WidgetRef ref) async {
    final created = await showNoteFormSheet(context, projectId);
    if (created == null) return;
    ref.invalidate(projectNotesProvider(projectId));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not kaydedildi')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(projectNotesProvider(projectId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canCreate =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.operations.manage');

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectNotesProvider(projectId)),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(child: Text('Proje Notları', style: TextStyle(fontWeight: FontWeight.w700))),
              if (canCreate)
                FilledButton.tonalIcon(
                  onPressed: () => _addNote(context, ref),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Not Ekle'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          AsyncStateView<List<ProjectNote>>(
            value: notesAsync,
            onRetry: () async => ref.invalidate(projectNotesProvider(projectId)),
            isEmpty: (notes) => notes.isEmpty,
            emptyBuilder: (_) => const EmptyStateView(message: 'Henüz not yok.'),
            data: (context, notes) => Column(
              children: [
                for (final note in notes)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(note.content),
                          const SizedBox(height: 8),
                          Text(
                            [
                              if (note.createdByName.isNotEmpty) note.createdByName,
                              if (note.createdAt.isNotEmpty) Formatters.dateTime(note.createdAt),
                            ].join(' · '),
                            style: const TextStyle(color: Colors.black54, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

