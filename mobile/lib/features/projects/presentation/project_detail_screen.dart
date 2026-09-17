import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';
import 'collection_form_sheet.dart';
import 'expense_form_sheet.dart';
import 'note_form_sheet.dart';

/// RBAC/Project Membership sprint'i: sekmeler kullanıcının izin kümesine
/// göre GİZLENİR (spec: "no finance section shown without finance
/// permission") -- bu YALNIZCA UX'tir, gerçek sınır zaten backend'de (bu
/// sekme gösterilse bile ilgili uç 403 döner). owner/admin/legacy_user
/// TÜM izinlere sahip olduğu için onlar için hiçbir sekme gizlenmez.
class _TabDef {
  const _TabDef(this.label, this.permission, this.builder);
  final String label;
  final String? permission; // null = her zaman görünür.
  final Widget Function(String projectId, Project project) builder;
}

final _tabDefs = <_TabDef>[
  _TabDef('Genel', null, (id, p) => _GeneralTab(project: p)),
  _TabDef('Finans', 'projects.finance.read', (id, p) => _FinanceTab(projectId: id, project: p)),
  // Sprint 3 — Ek İşler, mobilde YALNIZCA OKUMA (spec: read-only visibility
  // this sprint). İzin MEVCUT projects.finance.read'i yeniden kullanır --
  // Ek İşler bugün backend'de bu iznin altında yaşıyor, mobil için ayrı bir
  // izin tanımlanmadı (bkz. docs/contracts.md). Sözleşme'nin kendisi
  // mobilde YOK (yalnızca web) -- bu, yalnızca onu değiştiren Ek İşlerin
  // salt-okunur listesi.
  _TabDef('Ek İşler', 'projects.finance.read', (id, p) => _ChangeOrdersTab(projectId: id)),
  // Sprint 4 — Satın Alma, mobilde YALNIZCA OKUMA (bkz. domain/procurement.dart
  // dosya başı notu). Ek İşler'in aksine bu, bu sprint için tanımlanan YENİ
  // bir izin -- eski bir izin yeniden kullanılmıyor.
  _TabDef('Satın Alma', 'projects.procurement.read', (id, p) => _ProcurementTab(projectId: id)),
  // Sprint 2 — Maliyet Kontrolü, mobilde YALNIZCA OKUMA (spec: "no budget
  // editing, no manual commitment editing, no cost-code admin on mobile
  // this sprint -- web-first"). İzin, budget.read DEĞİL cost_control.read
  // (web'deki AYNI ayrım: cost_control.* özet/izleme katmanını kapsar).
  _TabDef('Maliyet Kontrolü', 'projects.cost_control.read', (id, p) => _CostControlTab(projectId: id, project: p)),
  // Sprint 5 follow-up — Taşeron Yönetimi (yeni modül, migration 0039).
  // Legacy Finans>Taşeronlar İLE KARIŞTIRILMAMALI (o mobilde HİÇ YOK,
  // bilinçli olarak buraya YATIRIM YAPILMIYOR, bkz. domain/subcontract.dart
  // dosya başı notu) -- bu, backend'in "product direction" olarak
  // işaretlediği YENİ modülün mobil karşılığı.
  _TabDef('Taşeronlar', 'projects.subcontracts.read', (id, p) => _SubcontractsTab(projectId: id)),
  _TabDef('Operasyon', 'projects.tasks.read', (id, p) => _OperationsTab(projectId: id)),
  _TabDef('Dosyalar', 'projects.operations.read', (id, p) => _FilesTab(projectId: id)),
  _TabDef('Notlar', 'projects.operations.read', (id, p) => _NotesTab(projectId: id)),
  _TabDef('Aktivite', null, (id, p) => _ActivityTab(projectId: id)),
];

class ProjectDetailScreen extends ConsumerWidget {
  const ProjectDetailScreen({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(projectDetailProvider(projectId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    // super_admin bu ekrana zaten hiç gelmez (mobil kapsamı yok); permissions
    // boşsa (nadir, henüz yüklenmemiş) TÜM sekmeler gösterilir -- geçici bir
    // "her şey gizli" yanılsaması yaratmamak için (backend zaten 403 üretir).
    final visibleTabs = user == null || user.permissions.isEmpty
        ? _tabDefs
        : _tabDefs.where((t) => t.permission == null || user.hasPermission(t.permission!)).toList();

    return DefaultTabController(
      length: visibleTabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: projectAsync.maybeWhen(
            data: (p) => Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            orElse: () => const Text('Proje'),
          ),
          bottom: TabBar(
            isScrollable: true,
            tabs: [for (final t in visibleTabs) Tab(text: t.label)],
          ),
        ),
        body: AsyncStateView(
          value: projectAsync,
          onRetry: () async => ref.invalidate(projectDetailProvider(projectId)),
          data: (context, project) => TabBarView(
            children: [for (final t in visibleTabs) t.builder(projectId, project)],
          ),
        ),
      ),
    );
  }
}

class _GeneralTab extends StatelessWidget {
  const _GeneralTab({required this.project});
  final Project project;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(project.projectNo, style: const TextStyle(fontWeight: FontWeight.w700)),
                    StatusRegistry.build(project.status, StatusRegistry.project),
                  ],
                ),
                const SizedBox(height: 12),
                _InfoRow(label: 'Proje Türü', value: project.projectType.isEmpty ? '-' : project.projectType),
                _InfoRow(
                    label: 'Sözleşme Tutarı',
                    value: Formatters.money(project.contractAmount, currency: project.currency)),
                _InfoRow(label: 'Başlangıç', value: Formatters.date(project.startDate)),
                _InfoRow(label: 'Bitiş', value: Formatters.date(project.endDate)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Müşteri Bilgileri', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                _InfoRow(label: 'Ad', value: project.customerName),
                _InfoRow(label: 'Telefon', value: project.customerPhone.isEmpty ? '-' : project.customerPhone),
                _InfoRow(label: 'E-posta', value: project.customerEmail.isEmpty ? '-' : project.customerEmail),
              ],
            ),
          ),
        ),
        if (project.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Açıklama', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(project.description),
                ],
              ),
            ),
          ),
        ],
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
              const Text('Masraflar', style: TextStyle(fontWeight: FontWeight.w700)),
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
              const Text('Tahsilatlar', style: TextStyle(fontWeight: FontWeight.w700)),
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
                const Text('Tahmini / Öngörülen', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.grey)),
                Text(
                  hasForecastBudget ? 'bütçeye göre (EAC)' : 'taahhüt bazlı',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
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

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectSubcontractsProvider(projectId)),
      child: AsyncStateView(
        value: subcontractsAsync,
        onRetry: () async => ref.invalidate(projectSubcontractsProvider(projectId)),
        isEmpty: (list) => list.isEmpty,
        emptyBuilder: (_) => const EmptyStateView(message: 'Henüz taşeron sözleşmesi yok.'),
        data: (context, subcontracts) => ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: subcontracts.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final sc = subcontracts[i];
            return Card(
              child: ListTile(
                title: Text('${sc.subcontractNo} — ${sc.supplierName ?? sc.supplierCode ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: StatusRegistry.build(sc.status, StatusRegistry.subcontract),
                trailing: Text(Formatters.money(sc.originalAmount, currency: sc.currency),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => context.push('/projeler/$projectId/taseronlar/${sc.id}'),
              ),
            );
          },
        ),
      ),
    );
  }
}

enum _ProcurementView { requests, orders }

/// Sprint 4 — Satın Alma, mobilde YALNIZCA OKUMA (bkz. domain/procurement.dart
/// dosya başı notu). RFQ/teklif karşılaştırma/tedarikçi/PO onay-iptal-kapatma
/// mobilde YOKTUR -- yalnızca Talep ve Sipariş listeleri arasında geçiş.
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentedButton<_ProcurementView>(
            segments: const [
              ButtonSegment(value: _ProcurementView.requests, label: Text('Talepler')),
              ButtonSegment(value: _ProcurementView.orders, label: Text('Siparişler')),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
        ),
        Expanded(
          child: _view == _ProcurementView.requests
              ? _PurchaseRequestsList(projectId: widget.projectId)
              : _PurchaseOrdersList(projectId: widget.projectId),
        ),
      ],
    );
  }
}

class _PurchaseRequestsList extends ConsumerWidget {
  const _PurchaseRequestsList({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestsAsync = ref.watch(projectPurchaseRequestsProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectPurchaseRequestsProvider(projectId)),
      child: AsyncStateView(
        value: requestsAsync,
        onRetry: () async => ref.invalidate(projectPurchaseRequestsProvider(projectId)),
        isEmpty: (list) => list.isEmpty,
        emptyBuilder: (_) => const EmptyStateView(message: 'Henüz satın alma talebi yok.'),
        data: (context, requests) => ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: requests.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final pr = requests[i];
            return Card(
              child: ListTile(
                title: Text('${pr.prNo} — ${pr.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: StatusRegistry.build(pr.status, StatusRegistry.purchaseRequest),
                trailing: Text(Formatters.money(pr.estimatedTotal), style: const TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => context.push('/projeler/$projectId/satin-alma/talepler/${pr.id}'),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PurchaseOrdersList extends ConsumerWidget {
  const _PurchaseOrdersList({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ordersAsync = ref.watch(projectPurchaseOrdersProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectPurchaseOrdersProvider(projectId)),
      child: AsyncStateView(
        value: ordersAsync,
        onRetry: () async => ref.invalidate(projectPurchaseOrdersProvider(projectId)),
        isEmpty: (list) => list.isEmpty,
        emptyBuilder: (_) => const EmptyStateView(message: 'Henüz satın alma siparişi yok.'),
        data: (context, orders) => ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: orders.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final po = orders[i];
            return Card(
              child: ListTile(
                title: Text('${po.poNo} — ${po.supplierName ?? po.supplierCode ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: StatusRegistry.build(po.status, StatusRegistry.purchaseOrder),
                trailing: Text(Formatters.money(po.total, currency: po.currency),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => context.push('/projeler/$projectId/satin-alma/siparisler/${po.id}'),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _OperationsTab extends ConsumerWidget {
  const _OperationsTab({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(projectTasksProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectTasksProvider(projectId)),
      child: AsyncStateView(
        value: tasksAsync,
        onRetry: () async => ref.invalidate(projectTasksProvider(projectId)),
        isEmpty: (list) => list.isEmpty,
        emptyBuilder: (_) => const EmptyStateView(message: 'Görev yok.'),
        data: (context, tasks) => ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: tasks.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final t = tasks[i];
            return Card(
              child: ListTile(
                leading: Checkbox(
                  value: t.status == 'completed',
                  onChanged: t.status == 'completed'
                      ? null
                      : (_) async {
                          await ref.read(projectsRepositoryProvider).completeTask(projectId, t.id);
                          ref.invalidate(projectTasksProvider(projectId));
                        },
                ),
                title: Text(
                  t.title,
                  style: t.status == 'completed' ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
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
                    if (t.isOverdue) const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
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

  Future<void> _pickAndUploadPhoto(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (picked == null) return;
    final file = File(picked.path);
    final size = await file.length();
    if (size > AppConfig.maxUploadBytes) {
      _showError('Fotoğraf 25 MiB sınırını aşıyor (${(size / 1024 / 1024).toStringAsFixed(1)} MB).');
      return;
    }
    setState(() => _uploading = true);
    try {
      await ref.read(projectsRepositoryProvider).uploadPhoto(
            projectId,
            filePath: picked.path,
            fileName: picked.name,
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
    if (picked.size > AppConfig.maxUploadBytes) {
      _showError('Dosya 25 MiB sınırını aşıyor (${(picked.size / 1024 / 1024).toStringAsFixed(1)} MB).');
      return;
    }
    setState(() => _uploading = true);
    try {
      await ref.read(projectsRepositoryProvider).uploadFile(
            projectId,
            filePath: picked.path!,
            fileName: picked.name,
          );
      ref.invalidate(projectFilesProvider(projectId));
    } on ApiException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
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
              const Text('Şantiye Fotoğrafları', style: TextStyle(fontWeight: FontWeight.w700)),
              Row(
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
                itemBuilder: (context, i) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    ref.read(projectsRepositoryProvider).photoContentUrl(projectId, photos[i].id),
                    width: 90,
                    height: 90,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 90,
                      height: 90,
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Dosyalar', style: TextStyle(fontWeight: FontWeight.w700)),
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
                          leading: const Icon(Icons.insert_drive_file_outlined),
                          title: Text(f.originalName, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${(f.sizeBytes / 1024).toStringAsFixed(0)} KB'),
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
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
              fontSize: emphasize ? 16 : 13,
              color: valueColor,
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
              const Text('Proje Notları', style: TextStyle(fontWeight: FontWeight.w700)),
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

