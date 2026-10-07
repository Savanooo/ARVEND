import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_status_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/quick_action_button.dart';
import '../../../core/widgets/status_badge.dart';
import '../../auth/domain/user.dart';
import '../../tasks/domain/task_filters.dart';
import '../../tasks/presentation/task_complete_checkbox.dart';
import '../activity/activity_routes.dart' show projectActivityPath;
import '../budget/budget_routes.dart' show budgetSections;
import '../budget/presentation/widgets/budget_ui.dart' show formatBudgetPercent;
import '../contract_co/contract_co_sections.dart' show ContractCoSectionEntry, contractCoSections;
import '../data/projects_providers.dart';
import '../domain/project.dart';
import '../domain/project_lock_text.dart';
import '../finance_ledger/data/finance_ledger_providers.dart' show invalidateProjectLedger, kLedgerReadPermission;
import '../finance_ledger/presentation/ledger_sections.dart';
import '../finance_ledger/presentation/ledger_ui.dart' show isLedgerLocked;
import '../finance_ledger/presentation/subcontractor_payments_tab.dart' show SubcontractorPaymentsTab;
import '../finance_plan/finance_plan_routes.dart' show financePlanViews, kPaymentPlanAlt;
import '../ops_team/ops_team_sections.dart' show opsTeamSections;
import '../projects_routes.dart';
import 'note_form_sheet.dart';
import 'project_sub_view_bar.dart';

/// RBAC/Project Membership sprint'i: gruplar kullanıcının izin kümesine
/// göre GİZLENİR (spec: "no finance section shown without finance
/// permission") -- bu YALNIZCA UX'tir, gerçek sınır zaten backend'de (bu
/// grup gösterilse bile ilgili uç 403 döner). owner/admin/legacy_user
/// TÜM izinlere sahip olduğu için onlar için hiçbir grup gizlenmez.
///
/// Redesign: eskiden 10 EŞİT AĞIRLIKLI sekme tek bir TabBar'daydı (bkz. git
/// geçmişi) -- şimdi 4 üst-seviye gruba (Özet/Finans/Operasyon/Dokümanlar)
/// toplanıyor, her biri KENDİ içinde alt-görünümler ([_SubViewDef]) arasında
/// yatay kaydırılabilir bir çip satırıyla geçer. Aktivite birincil bir sekme
/// DEĞİL, AppBar'daki bir simge üzerinden açılan ayrı bir ekran.
///
/// Bir grup, alt görünümlerinden EN AZ BİRİ görünürse görünür (Özet her
/// zaman). Böylece ör. finans izni olmayan ama sözleşme izni olan Proje
/// Yöneticisi de Finans grubunu (yalnızca Sözleşme ile) görür -- web'de
/// canlı doğrulamada bulunmuş hatanın mobil karşılığı (docs/contracts.md §11).
class _GroupDef {
  const _GroupDef(this.label, {this.icon = Icons.circle_outlined, this.views = const []});
  final String label;
  final IconData icon;

  /// Boş = Özet (kendi iniş sekmesi, alt görünümü yok).
  final List<_SubViewDef> views;

  bool get isOverview => views.isEmpty;

  bool visible(User? user) => isOverview || views.any((v) => v.visible(user));
}

/// Bir grubun alt görünümü: `?alt=` değeri, çip etiketi, görünürlük izni ve
/// gövde. Gövde grubun `Expanded` alanına konur ve kendi kaydırılabilir
/// listesini + RefreshIndicator'ını taşır. Yeni modüller (Sözleşme, Ek
/// İşler, Ödeme Planı, Faturalar, Maliyet Kontrolü, Planlama, Ekip, Erişim)
/// kendi klasörlerindeki tanımlardan (`*_sections.dart` / `*_routes.dart`)
/// buraya bağlanır; her gövde yazma aksiyonlarını kendi izniyle ayrıca gizler.
class _SubViewDef {
  const _SubViewDef({
    required this.alt,
    required this.label,
    required this.navWord,
    required this.visible,
    required this.builder,
  });

  /// `?alt=` değeri (ana sayfa derin bağlantısı, bkz. mobileRouteFor).
  final String alt;
  final String label;

  /// Özet'teki grup kartının alt metninde kullanılan küçük harfli ad.
  final String navWord;
  final bool Function(User? user) visible;
  final Widget Function(String projectId, Project project) builder;
}

/// Derin bağlantı `?grup=` değeri -> grup etiketi (ana sayfa, spec D4).
const _groupParam = {
  'ozet': 'Özet',
  'finans': 'Finans',
  'operasyon': 'Operasyon',
  'dokumanlar': 'Dokümanlar',
};

/// Özet'teki bir hızlı işlemin açtırmak istediği alt görünüm (ör.
/// "Fotoğraf Ekle" -> Dokümanlar > Dosyalar). Grup sekmesi en son hangi alt
/// görünümde bırakıldıysa (ör. Notlar) orada açılıyordu. [seq] aynı isteğin
/// art arda tekrarını ayırt eder.
final _subViewRequestProvider =
    StateProvider.autoDispose.family<({String alt, int seq})?, String>((ref, projectId) => null);

bool _failOpen(User? user, String permission) =>
    user == null || user.permissions.isEmpty || user.hasPermission(permission);

/// Sözleşme/Ek İşler ve Maliyet Kontrolü tanımları (aynı kayıt tipi):
/// `anyOfPermissions`'tan HERHANGİ biri yeter (fail-open, `_failOpen`).
_SubViewDef _fromSection(ContractCoSectionEntry s, {required String navWord}) {
  final codes = s.anyOfPermissions.isEmpty ? [s.permission] : s.anyOfPermissions;
  return _SubViewDef(
    alt: s.alt,
    label: s.label,
    navWord: navWord,
    visible: (user) => codes.any((code) => _failOpen(user, code)),
    builder: s.builder,
  );
}

/// Finans grubu -- web "Finans" + "Maliyet Kontrolü" sekmeleri. Sıra: mevcut
/// Finans (özet + masraf + tahsilat) iniş görünümü olarak başta kalır; web'deki
/// gibi Sözleşme, Ek İşler'in önünde.
final List<_SubViewDef> _finansViews = [
  // Etiket grubun adını ("Finans") tekrar etmez: çip ne içerdiğini söyler
  // (kârlılık özeti + Masraflar + Tahsilatlar). `?alt=finans` aynı kalır.
  _SubViewDef(
    alt: 'finans',
    label: 'Masraf & Tahsilat',
    navWord: 'tahsilat/masraf',
    visible: (user) => _failOpen(user, 'projects.finance.read'),
    builder: (id, p) => _FinanceTab(projectId: id, project: p),
  ),
  // Kendi 3 katmanlı izni (contracts.read/manage/lifecycle) -- finance.read'e
  // BAĞLI DEĞİL.
  _fromSection(contractCoSections.firstWhere((s) => s.alt == 'sozlesme'), navWord: 'sözleşme'),
  for (final v in financePlanViews)
    _SubViewDef(
      alt: v.alt,
      label: v.label,
      navWord: v.alt == kPaymentPlanAlt ? 'ödeme planı' : 'faturalar',
      visible: v.visibleFor,
      builder: (id, p) => v.tabBuilder(id),
    ),
  // Web Finans > "Taşeronlar" (legacy taşeron kaydı + GERÇEK ödemeler;
  // gerçekleşen maliyete girer). Operasyon > Taşeronlar'daki taşeron
  // SÖZLEŞMELERİYLE (SOV/hakediş) karışmasın diye mobilde bu adla.
  _SubViewDef(
    alt: 'taseron-odemeleri',
    label: 'Taşeron Ödemeleri',
    navWord: 'taşeron ödemeleri',
    visible: (user) => _failOpen(user, kLedgerReadPermission),
    builder: (id, p) => SubcontractorPaymentsTab(projectId: id, project: p),
  ),
  _fromSection(contractCoSections.firstWhere((s) => s.alt == 'ek-isler'), navWord: 'ek işler'),
  // cost_control.read VEYA budget.read (bütçe/WBS/revizyon ayrı izin).
  for (final s in budgetSections) _fromSection(s, navWord: 'maliyet kontrolü'),
];

/// Operasyon grubu -- web "Satın Alma" + "Operasyon" sekmeleri (taşeron
/// sözleşmeleri de burada). Planlama/Ekip `projects.operations.read`,
/// Erişim `projects.access.read`.
final List<_SubViewDef> _operasyonViews = [
  _SubViewDef(
    alt: 'taseronlar',
    label: 'Taşeronlar',
    navWord: 'taşeronlar',
    visible: (user) => _failOpen(user, 'projects.subcontracts.read'),
    builder: (id, p) => _SubcontractsTab(projectId: id),
  ),
  _SubViewDef(
    alt: 'satin-alma',
    label: 'Satın Alma',
    navWord: 'satın alma',
    visible: (user) => _failOpen(user, 'projects.procurement.read'),
    builder: (id, p) => _ProcurementTab(projectId: id),
  ),
  _SubViewDef(
    alt: 'gorevler',
    label: 'Görevler',
    navWord: 'görevler',
    visible: (user) => _failOpen(user, 'projects.tasks.read'),
    builder: (id, p) => _OperationsTab(projectId: id, locked: isProjectClosed(p.status)),
  ),
  for (final s in opsTeamSections)
    _SubViewDef(
      alt: s.alt,
      label: s.label,
      navWord: switch (s.alt) {
        'erisim' => 'proje erişimi',
        'ekip' => 'ekip',
        _ => 'planlama',
      },
      visible: s.visibleFor,
      builder: s.builder,
    ),
];

/// Dokümanlar grubu -- ikisi de AYNI izni (`projects.operations.read`) paylaşır.
final List<_SubViewDef> _dokumanlarViews = [
  _SubViewDef(
    alt: 'dosyalar',
    label: 'Dosyalar',
    navWord: 'dosyalar, fotoğraflar',
    visible: (user) => _failOpen(user, 'projects.operations.read'),
    builder: (id, p) => _FilesTab(projectId: id, locked: isProjectClosed(p.status)),
  ),
  _SubViewDef(
    alt: 'notlar',
    label: 'Notlar',
    navWord: 'notlar',
    visible: (user) => _failOpen(user, 'projects.operations.read'),
    builder: (id, p) => _NotesTab(projectId: id),
  ),
];

final _groupDefs = <_GroupDef>[
  const _GroupDef('Özet'),
  _GroupDef('Finans', icon: Icons.account_balance_wallet_outlined, views: _finansViews),
  _GroupDef('Operasyon', icon: Icons.engineering_outlined, views: _operasyonViews),
  _GroupDef('Dokümanlar', icon: Icons.folder_outlined, views: _dokumanlarViews),
];

/// Özet'teki grup kartı alt metni -- YALNIZCA kullanıcının görebildiği alt
/// görünümlerden ("Sözleşme, ödeme planı ve ek işler").
String _navSubtitle(Iterable<_SubViewDef> views) {
  final words = [for (final v in views) v.navWord];
  if (words.isEmpty) return '';
  final text = words.length == 1
      ? words.single
      : '${words.sublist(0, words.length - 1).join(', ')} ve ${words.last}';
  final first = text[0] == 'i' ? 'İ' : text[0].toUpperCase();
  return '$first${text.substring(1)}';
}

class ProjectDetailScreen extends ConsumerWidget {
  const ProjectDetailScreen({super.key, required this.projectId, this.initialGroup, this.initialView});
  final String projectId;

  /// `?grup=ozet|finans|operasyon|dokumanlar` -- görünür değilse Özet.
  final String? initialGroup;

  /// `?alt=` -- grubun alt görünümü (finans|sozlesme|odeme-plani|faturalar|
  /// ek-isler|maliyet, taseronlar|satin-alma|gorevler|planlama|ekip|erisim,
  /// dosyalar|notlar); görünür değilse grubun ilk görünür alt görünümü.
  final String? initialView;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(projectDetailProvider(projectId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    // Alt görünüm isteği, hedef sekme henüz kurulmamışken de yaşasın.
    ref.listen(_subViewRequestProvider(projectId), (_, _) {});
    final visibleGroups = _groupDefs.where((g) => g.visible(user)).toList();
    final requestedLabel = _groupParam[initialGroup];
    final initialIndex = requestedLabel == null ? 0 : visibleGroups.indexWhere((g) => g.label == requestedLabel);

    return DefaultTabController(
      // Görünür grup kümesi değişince (ör. /auth/me henüz yüklenmemişken
      // fail-open 4 grup, yüklenince 3) denetleyici YENİDEN kurulur -- aksi
      // halde eski uzunlukla hesaplanan indeks korunur ve `?grup=operasyon`
      // derin bağlantısı yanlış gruba (Dokümanlar) düşerdi.
      key: ValueKey(visibleGroups.map((g) => g.label).join('|')),
      length: visibleGroups.length,
      initialIndex: initialIndex < 0 ? 0 : initialIndex,
      child: AppPageScaffold(
        title: projectAsync.maybeWhen(
          data: (p) => Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          orElse: () => const Text('Proje'),
        ),
        actions: [
          // Web ile aynı: "Düzenle" yalnızca projects.update ile (katı kontrol).
          if (user.canAccess('projects.update') && projectAsync.hasValue)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Düzenle',
              onPressed: () => context.push(projectEditLocation(projectId)),
            ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Aktivite Geçmişi',
            onPressed: () => context.push(projectActivityPath(projectId)),
          ),
        ],
        bottom: TabBar(
          isScrollable: true,
          // Material 3'ün kaydırılabilir varsayılanı (startOffset) sola ~52 dp
          // boşluk bırakıp 360 dp'de son sekmeyi ("Dokümanlar") kesiyordu.
          tabAlignment: TabAlignment.start,
          labelPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          tabs: [for (final g in visibleGroups) Tab(text: g.label)],
        ),
        body: AsyncStateView(
          value: projectAsync,
          onRetry: () async => ref.invalidate(projectDetailProvider(projectId)),
          data: (context, project) => TabBarView(
            children: [
              // Sayfalar canlı tutulur: TabBarView (PageView) ekran dışındaki
              // grubu atar; seçili alt görünüm çipi ve liste kaydırma konumu
              // gruplar arasında gidip gelince kaybolmasın (ör. Finans > Ek
              // İşler -> Operasyon -> geri Finans yine Ek İşler'de açılır).
              for (final g in visibleGroups)
                _KeepAlivePage(
                  key: ValueKey('proje-grup-${g.label}'),
                  child: g.isOverview
                      ? _OverviewTab(projectId: projectId, project: project)
                      : _SubViewGroupTab(
                          projectId: projectId,
                          project: project,
                          views: g.views,
                          initialView: g.label == requestedLabel ? initialView : null,
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// TabBarView sayfasını ekran dışındayken de canlı tutar (bkz. yukarı).
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({super.key, required this.child});
  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
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

    void goToGroup(String label, {String? alt}) {
      final index = visibleGroups.indexWhere((g) => g.label == label);
      if (index < 0) return;
      if (alt != null) {
        final request = ref.read(_subViewRequestProvider(projectId).notifier);
        request.state = (alt: alt, seq: (request.state?.seq ?? 0) + 1);
      }
      DefaultTabController.of(context).animateTo(index);
    }

    final canFinance = _failOpen(user, 'projects.finance.read');
    // Masraf/tahsilat EKLEME (yazma) `projects.finance.manage` ister --
    // `projects.finance.read` yalnızca GÖRÜNTÜLEMEYİ (özet/liste) yetkilendirir,
    // ikisi backend'de AYRI iki izin kodu (bkz. router.go finans grubu).
    final canManageFinance = _failOpen(user, 'projects.finance.manage');
    // Kapalı projede görev oluşturma ve yükleme reddedilir (backend
    // requireOpenProject) -- hızlı işlem de gösterilmez; sekmeler nedenini
    // söyler.
    final closed = isProjectClosed(project.status);
    final canCreateTask = _failOpen(user, 'projects.tasks.create') && !closed;
    final canManageFiles = _failOpen(user, 'projects.operations.manage') && !closed;

    // Tamamlanmış/iptal edilmiş projede finans hareketi girilemez (backend
    // 409, web `locked`) -- hızlı işlem de gösterilmez.
    final canAddLedger = canManageFinance && !isLedgerLocked(project.status);
    final canReadOffers = _failOpen(user, 'offers.read');
    final canReadCustomers = _failOpen(user, 'customers.read');

    final summaryAsync = canFinance ? ref.watch(projectFinancialSummaryProvider(projectId)) : null;

    final quickActions = <QuickActionButton>[
      if (canAddLedger)
        QuickActionButton(
          icon: Icons.receipt_long_outlined,
          label: 'Masraf Ekle',
          onPressed: () => addProjectExpense(context, project),
        ),
      if (canAddLedger)
        QuickActionButton(
          icon: Icons.payments_outlined,
          label: 'Tahsilat Ekle',
          onPressed: () => addProjectCollection(context, project),
        ),
      if (canCreateTask)
        QuickActionButton(
          icon: Icons.checklist_outlined,
          label: 'Görev Ekle',
          onPressed: () => context.push('/projeler/$projectId/gorevler/yeni'),
        ),
      if (canManageFiles)
        QuickActionButton(
          icon: Icons.photo_camera_outlined,
          label: 'Fotoğraf Ekle',
          // Dokümanlar'ın Notlar'da kalmış olabilir: doğrudan Dosyalar'ın
          // başına (Fotoğraf Çek / Galeriden Seç) gidilir.
          onPressed: () => goToGroup('Dokümanlar', alt: 'dosyalar'),
        ),
    ];

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
              // Tutar yalnızca finans görüntüleme iznine sahip kişiye (web
              // "Ana Sözleşme Bedeli"ni tüm proje okuyucularına gösterir;
              // mobil kuralı daha sıkı: finans izni yoksa hiç para yok).
              if (canFinance)
                _InfoRow(
                    label: 'Sözleşme Tutarı',
                    value: Formatters.money(project.contractAmount, currency: project.currency)),
              _InfoRow(label: 'Başlangıç', value: Formatters.date(project.startDate)),
              _InfoRow(label: 'Bitiş', value: Formatters.date(project.endDate)),
              // Web "Kaynak Teklif": teklif no · revizyon; teklif okuma izni
              // varsa teklife gider.
              if (project.sourceOfferNo.isNotEmpty)
                InkWell(
                  onTap: canReadOffers && project.sourceOfferId != null
                      ? () => context.push('/teklifler/${Uri.encodeComponent(project.sourceOfferId!)}')
                      : null,
                  child: _InfoRow(
                    label: 'Kaynak Teklif',
                    value: [
                      project.sourceOfferNo,
                      if (project.sourceRevisionNo != null) 'Rev. ${project.sourceRevisionNo}',
                    ].join(' · '),
                    valueColor: canReadOffers && project.sourceOfferId != null ? AppColors.info : null,
                  ),
                ),
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
              _InfoRow(label: 'Adres', value: project.customerAddress.isEmpty ? '-' : project.customerAddress),
              // Web "Müşteri kartını aç →" -- kayıtlı müşteriye bağlıysa ve
              // müşteri okuma izni varsa.
              if (project.customerId != null && project.customerId!.isNotEmpty && canReadCustomers) ...[
                const SizedBox(height: AppSpacing.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    icon: const Icon(Icons.person_outline, size: 18),
                    label: const Text('Müşteri kartını aç'),
                    onPressed: () => context.push('/diger/musteriler/${Uri.encodeComponent(project.customerId!)}'),
                  ),
                ),
              ],
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
        // Web "Dahili Notlar (müşteri görmez)" -- proje düzenle ekranından yazılır.
        if (project.internalNotes.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Dahili Notlar (müşteri görmez)', style: AppTypography.cardTitle),
                const SizedBox(height: AppSpacing.sm),
                Text(project.internalNotes, style: AppTypography.body),
              ],
            ),
          ),
        ],
        // Başlık yalnızca en az bir işlem varsa: hiçbir yetkisi olmayan kişi
        // altı boş bir "Hızlı İşlemler" başlığı görmesin.
        if (quickActions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          const AppSectionHeader(title: 'Hızlı İşlemler'),
          const SizedBox(height: AppSpacing.sm),
          QuickActionGrid(children: quickActions),
        ],
        if (summaryAsync != null) ...[
          const SizedBox(height: AppSpacing.lg),
          const AppSectionHeader(title: 'Finansal Özet'),
          const SizedBox(height: AppSpacing.sm),
          AsyncStateView(
            value: summaryAsync,
            onRetry: () async => ref.invalidate(projectFinancialSummaryProvider(projectId)),
            data: (context, s) => _FinancialSummaryCard(summary: s),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        const AppSectionHeader(title: 'Proje Alanları'),
        const SizedBox(height: AppSpacing.sm),
        for (final group in visibleGroups.where((g) => !g.isOverview))
          _GroupNavCard(
            label: group.label,
            subtitle: _navSubtitle(group.views.where((v) => v.visible(user))),
            icon: group.icon,
            onTap: () => goToGroup(group.label),
          ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          // Aktivite birincil bir sekme DEĞİL -- AppBar simgesi ve bu kart
          // aynı tam ekrana (/projeler/:id/aktivite) açılır.
          onTap: () => context.push(projectActivityPath(projectId)),
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
                Text(subtitle, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}

/// Bir grubun gövdesi: üstte alt görünüm çipleri, altında seçili görünümün
/// gövdesi. Her alt görünüm İZNİNE göre ayrı ayrı gizlenir -- grubun kendisi
/// görünürse bile alt görünümlerden biri gizli kalabilir. `?alt=` ile gelen
/// görünüm görünür değilse ilk görünür alt görünüm açılır.
class _SubViewGroupTab extends ConsumerStatefulWidget {
  const _SubViewGroupTab({
    required this.projectId,
    required this.project,
    required this.views,
    this.initialView,
  });
  final String projectId;
  final Project project;
  final List<_SubViewDef> views;

  /// `?alt=` (ana sayfa derin bağlantısı).
  final String? initialView;

  @override
  ConsumerState<_SubViewGroupTab> createState() => _SubViewGroupTabState();
}

class _SubViewGroupTabState extends ConsumerState<_SubViewGroupTab> {
  String? _alt;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final visible = widget.views.where((v) => v.visible(user)).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    ref.listen(_subViewRequestProvider(widget.projectId), (_, next) {
      if (next != null && visible.any((v) => v.alt == next.alt)) setState(() => _alt = next.alt);
    });
    final pending = ref.read(_subViewRequestProvider(widget.projectId));
    if (_alt == null && pending != null && visible.any((v) => v.alt == pending.alt)) _alt = pending.alt;
    _alt ??= visible.any((v) => v.alt == widget.initialView) ? widget.initialView : visible.first.alt;
    // İzin kümesi sonradan değişip seçili görünüm gizlendiyse ilkine düşülür.
    final current = visible.firstWhere((v) => v.alt == _alt, orElse: () => visible.first);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProjectSubViewBar(
          items: [for (final v in visible) (alt: v.alt, label: v.label)],
          selected: current.alt,
          onSelected: (alt) => setState(() => _alt = alt),
        ),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey('proje-alt-govde-${current.alt}'),
            child: current.builder(widget.projectId, widget.project),
          ),
        ),
      ],
    );
  }
}

/// Finans > "Finans" (iniş görünümü): özet kartı + Masraflar + Tahsilatlar
/// (web ExpensesSection / CollectionsSection). Satırlar dokununca ayrıntı +
/// "İptal Et" açar; ekleme/iptal `projects.finance.manage` + açık proje
/// ister (bölümler kendi içinde denetler). Ödeme Planı, Faturalar, Taşeron
/// Ödemeleri, Sözleşme, Ek İşler ve Maliyet Kontrolü aynı grubun ayrı alt
/// görünümleridir.
class _FinanceTab extends ConsumerWidget {
  const _FinanceTab({required this.projectId, required this.project});
  final String projectId;
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(projectFinancialSummaryProvider(projectId));
    // Tahminin bütçe (EAC) mi taahhüt bazlı mı olacağını sunucu seçer --
    // Maliyet Kontrolü izni (projects.cost_control.read) olmayana bütçe
    // bazlı rakam göstermez.

    return RefreshIndicator(
      onRefresh: () async => invalidateProjectLedger(ref.invalidate, projectId),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AsyncStateView(
            value: summaryAsync,
            onRetry: () async => ref.invalidate(projectFinancialSummaryProvider(projectId)),
            data: (context, s) => _FinancialSummaryCard(summary: s),
          ),
          const SizedBox(height: AppSpacing.lg),
          LedgerLockedNotice(project: project),
          ExpensesLedgerSection(project: project),
          const SizedBox(height: AppSpacing.xl),
          CollectionsLedgerSection(project: project),
          const SizedBox(height: AppSpacing.lg),
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
  const _FinancialSummaryCard({required this.summary});
  final FinancialSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    // Kâr hem KDV hariç hem KDV dahil (ürün sahibi kararı, 2026-10-06).
    // Tahmini bölümün kaynağını (bütçe EAC / taahhüt) SUNUCU seçer -- web
    // ile aynı rakam; burada hesap yapılmaz.
    final vat = s.contractVatKnown;
    Color tone(double v) => v < 0 ? AppStatusColors.error : AppStatusColors.success;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Özet', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            _InfoRow(
              label: vat ? 'Sözleşme Bedeli (KDV dahil)' : 'Satış / Sözleşme Bedeli',
              value: Formatters.money(s.currentContractValue, currency: s.currency),
              emphasize: true,
            ),
            if (vat)
              _InfoRow(
                label: 'KDV hariç',
                value: Formatters.money(s.currentContractValueNet, currency: s.currency),
              ),
            _InfoRow(label: 'Tahsil Edilen', value: Formatters.money(s.collectedAmount, currency: s.currency)),
            _InfoRow(label: 'Kalan Alacak', value: Formatters.money(s.remainingReceivable, currency: s.currency)),
            const Divider(height: 24),
            const Text('Gerçekleşen', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 4),
            _InfoRow(label: 'Gerçekleşen Maliyet', value: Formatters.money(s.realizedCost, currency: s.currency)),
            if (vat)
              _InfoRow(
                label: 'Kâr (KDV hariç)',
                value: Formatters.money(s.realizedGrossProfitNet, currency: s.currency),
                valueColor: tone(s.realizedGrossProfitNet),
              ),
            _InfoRow(
              label: vat ? 'Kâr (KDV dahil)' : 'Gerçekleşen Kâr',
              value: Formatters.money(s.realizedGrossProfit, currency: s.currency),
              valueColor: tone(s.realizedGrossProfit),
            ),
            // Türkçe ondalık virgül -- Maliyet Kontrolü'ndeki marjla aynı biçim
            // ("%32,78", "%35").
            _InfoRow(
              label: vat ? 'Marj (KDV hariç / dahil)' : 'Gerçekleşen Marj',
              value: vat
                  ? '${formatBudgetPercent(s.realizedMarginPercentNet)} / ${formatBudgetPercent(s.realizedMarginPercent)}'
                  : formatBudgetPercent(s.realizedMarginPercent),
            ),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Flexible(
                  child: Text('Tahmini / Öngörülen',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppColors.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    s.forecastFromBudget ? 'bütçeye göre (EAC)' : 'taahhüt bazlı',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _InfoRow(label: 'Tahmini Maliyet', value: Formatters.money(s.forecastCost, currency: s.currency)),
            if (vat)
              _InfoRow(
                label: 'Tahmini Kâr (KDV hariç)',
                value: Formatters.money(s.forecastProfitNet, currency: s.currency),
                valueColor: tone(s.forecastProfitNet),
              ),
            _InfoRow(
              label: vat ? 'Tahmini Kâr (KDV dahil)' : 'Tahmini Kâr',
              value: Formatters.money(s.forecastProfit, currency: s.currency),
              valueColor: tone(s.forecastProfit),
            ),
            _InfoRow(
              label: vat ? 'Tahmini Marj (KDV hariç / dahil)' : 'Tahmini Marj',
              value: vat
                  ? '${formatBudgetPercent(s.forecastMarginPercentNet)} / ${formatBudgetPercent(s.forecastMarginPercent)}'
                  : formatBudgetPercent(s.forecastMarginPercent),
            ),
          ],
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
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AppSectionHeader(
            title: 'Taşeron Sözleşmeleri',
            trailing: canCreate
                ? IconButton(
                    onPressed: () => context.push('/projeler/$projectId/taseronlar/yeni'),
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'Taşeron Sözleşmesi Ekle',
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          AsyncStateView(
            value: subcontractsAsync,
            onRetry: () async => ref.invalidate(projectSubcontractsProvider(projectId)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const EmptyStateView(message: 'Henüz taşeron sözleşmesi yok.'),
            data: (context, subcontracts) => Column(
              children: subcontracts
                  .map((sc) => AppListCard(
                        title: '${sc.subcontractNo} — ${sc.supplierName ?? sc.supplierCode ?? ''}',
                        onTap: () => context.push('/projeler/$projectId/taseronlar/${sc.id}'),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            StatusRegistry.build(sc.status, StatusRegistry.subcontract),
                            const SizedBox(height: 4),
                            MoneyText(sc.originalAmount, currency: sc.currency, style: AppTypography.metadata),
                          ],
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
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xs),
          child: Text(
            'Talep  →  RFQ  →  Teklif  →  Karşılaştırma  →  Sipariş',
            style: AppTypography.helper,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
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
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
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
                  .map((pr) => AppListCard(
                        title: '${pr.prNo} — ${pr.title}',
                        onTap: () => context.push('/projeler/$projectId/satin-alma/talepler/${pr.id}'),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            StatusRegistry.build(pr.status, StatusRegistry.purchaseRequest),
                            const SizedBox(height: 4),
                            MoneyText(pr.estimatedTotal, style: AppTypography.metadata),
                          ],
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
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
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
                  .map((r) => AppListCard(
                        title: '${r.rfqNo} — ${r.title}',
                        onTap: () => context.push('/projeler/$projectId/satin-alma/rfqlar/${r.id}'),
                        trailing: r.isAwarded
                            ? StatusRegistry.awardedQuotation
                            : StatusRegistry.build(r.status, StatusRegistry.rfq),
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
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
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
                  .map((po) => AppListCard(
                        title: '${po.poNo} — ${po.supplierName ?? po.supplierCode ?? ''}',
                        onTap: () => context.push('/projeler/$projectId/satin-alma/siparisler/${po.id}'),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            StatusRegistry.build(po.status, StatusRegistry.purchaseOrder),
                            const SizedBox(height: 4),
                            MoneyText(po.total, currency: po.currency, style: AppTypography.metadata),
                          ],
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
  const _OperationsTab({required this.projectId, required this.locked});
  final String projectId;

  /// Proje tamamlandı/iptal: yeni görev yok (mevcutlar tamamlanabilir).
  final bool locked;

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
    final canCreate =
        (user == null || user.permissions.isEmpty || user.hasPermission('projects.tasks.create')) && !widget.locked;

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
          if (widget.locked) ...[
            const SizedBox(height: AppSpacing.sm),
            const ReadOnlyNotice(kProjectTasksLockedText),
            const SizedBox(height: AppSpacing.sm),
          ],
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
                  child: Center(child: Text('Bu filtreye uyan görev yok.', style: TextStyle(color: AppColors.textMuted))),
                );
              }
              return Column(
                children: tasks
                    .map((t) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            onTap: () => context.push('/projeler/${widget.projectId}/gorevler/${t.id}'),
                            leading: TaskCompleteCheckbox(projectId: widget.projectId, task: t),
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
                                    child: Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.danger),
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
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

class _FilesTab extends ConsumerStatefulWidget {
  const _FilesTab({required this.projectId, required this.locked});
  final String projectId;

  /// Proje tamamlandı/iptal: yükleme yok (backend reddeder); silme ve
  /// görüntüleme sürer.
  final bool locked;

  @override
  ConsumerState<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<_FilesTab> {
  String get projectId => widget.projectId;
  bool _uploading = false;
  String? _openingFileId;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

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
      _showError('Fotoğraf 25 MiB sınırını aşıyor (${Formatters.fileSize(size)}).');
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
      _showError('Dosya 25 MiB sınırını aşıyor (${Formatters.fileSize(picked.size)}).');
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
      unawaited(ref.read(projectPhotoCacheProvider).remove(photo.id));
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

  String _fileType(String originalName) {
    final dot = originalName.lastIndexOf('.');
    if (dot < 0 || dot == originalName.length - 1) return '—';
    return originalName.substring(dot + 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final photosAsync = ref.watch(projectPhotosProvider(projectId));
    final filesAsync = ref.watch(projectFilesProvider(projectId));
    final canManage = _canManage;
    // Kapalı projede yükleme reddedilir; silme backend'de serbest.
    final canUpload = canManage && !widget.locked;
    // "Fotoğraf Ekle" (Özet): yükleme düğmelerinin olduğu başa dön.
    ref.listen(_subViewRequestProvider(projectId), (_, next) {
      if (next?.alt == 'dosyalar' && _scroll.hasClients) {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });

    // Fotoğraf ızgarası TEMBEL (SliverGrid): yalnızca ekrandaki kutucuklar
    // kurulur, bayt ister ve küçük boyutta çözülür. Eskiden shrinkWrap bir
    // GridView'du -- Dökümanlar her açıldığında 60 fotoğrafın HEPSİ tam
    // boyutta indirilip çözülüyordu (takılma, bellek taşması riski). Yükleme
    // düğmeleri ve dosya listesi fotoğraflardan ÖNCE: onlara ulaşmak için
    // bütün fotoğrafların üzerinden kaydırmak gerekmez.
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(projectPhotosProvider(projectId));
        ref.invalidate(projectFilesProvider(projectId));
      },
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (_uploading) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (widget.locked) ...[
                  const ReadOnlyNotice(kProjectUploadsLockedText),
                  const SizedBox(height: AppSpacing.md),
                ],
                if (canUpload) ...[
                  Row(
                    children: [
                      Expanded(
                        child: SecondaryButton(
                          icon: Icons.photo_camera_outlined,
                          label: 'Fotoğraf Çek',
                          onPressed: _uploading ? null : () => _pickAndUploadPhoto(ImageSource.camera),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: SecondaryButton(
                          icon: Icons.photo_library_outlined,
                          label: 'Galeriden Seç',
                          onPressed: _uploading ? null : () => _pickAndUploadPhoto(ImageSource.gallery),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(
                    width: double.infinity,
                    child: SecondaryButton(
                      icon: Icons.upload_file_outlined,
                      label: 'Dosya Seç',
                      onPressed: _uploading ? null : _pickAndUploadFile,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
                const AppSectionHeader(title: 'Dosyalar'),
                const SizedBox(height: AppSpacing.sm),
                AsyncStateView(
                  value: filesAsync,
                  onRetry: () async => ref.invalidate(projectFilesProvider(projectId)),
                  isEmpty: (l) => l.isEmpty,
                  emptyBuilder: (_) => const EmptyStateView(message: 'Dosya yok.', icon: Icons.insert_drive_file_outlined),
                  data: (context, files) => Column(
                    children: [
                      for (final f in files)
                        _FileRow(
                          file: f,
                          type: _fileType(f.originalName),
                          opening: _openingFileId == f.id,
                          onTap: _openingFileId != null ? null : () => _openFile(f),
                          onDelete: canManage ? () => _deleteFile(f) : null,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                AppSectionHeader(
                  title: [
                    'Şantiye Fotoğrafları',
                    if (photosAsync.valueOrNull?.isNotEmpty ?? false) '(${photosAsync.valueOrNull!.length})',
                  ].join(' '),
                ),
                const SizedBox(height: AppSpacing.sm),
              ]),
            ),
          ),
          ...photosAsync.when(
            data: (photos) => [
              if (photos.isEmpty)
                const SliverToBoxAdapter(
                  child: EmptyStateView(message: 'Fotoğraf yok.', icon: Icons.photo_camera_outlined),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: AppSpacing.sm,
                      crossAxisSpacing: AppSpacing.sm,
                    ),
                    itemCount: photos.length,
                    itemBuilder: (context, i) {
                      final photo = photos[i];
                      return _PhotoTile(
                        key: ValueKey('proje-foto-${photo.id}'),
                        projectId: projectId,
                        photo: photo,
                        onTap: () => _openPhotoViewer(photo),
                        onLongPress: canManage ? () => _deletePhoto(photo) : null,
                      );
                    },
                  ),
                ),
            ],
            loading: () => const [SliverToBoxAdapter(child: LoadingState())],
            error: (e, _) => [
              SliverToBoxAdapter(
                child: ErrorState(error: e, onRetry: () async => ref.invalidate(projectPhotosProvider(projectId))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Dosya satırı: ad, açıklama (varsa, 2 satıra kadar -- eskiden hiç
/// gösterilmiyordu), tür · tarih · boyut, kategori rozeti ve silme.
class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.type,
    required this.opening,
    required this.onTap,
    required this.onDelete,
  });

  final ProjectFile file;
  final String type;
  final bool opening;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final description = file.description.trim();
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          opening
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : const Icon(Icons.insert_drive_file_outlined, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(file.originalName, style: AppTypography.cardTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(description, style: AppTypography.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 2),
                Text(
                  '$type · ${Formatters.date(file.createdAt)} · ${Formatters.fileSize(file.sizeBytes)}',
                  style: AppTypography.metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          StatusRegistry.build(file.category, StatusRegistry.fileCategory),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Dosyayı sil',
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}

/// Izgaradaki tek fotoğraf: bayt yalnızca kutucuk kurulunca (ekrandayken)
/// istenir ve kutucuk boyutunda çözülür (`cacheWidth`) -- 12 MP'lik bir
/// fotoğraf ~100 dp'lik kutucuk için tam çözünürlükte belleğe açılmaz.
class _PhotoTile extends ConsumerWidget {
  const _PhotoTile({
    super.key,
    required this.projectId,
    required this.photo,
    required this.onTap,
    required this.onLongPress,
  });

  final String projectId;
  final ProjectPhoto photo;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytesAsync = ref.watch(projectPhotoBytesProvider((projectId: projectId, photoId: photo.id)));
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            fit: StackFit.expand,
            children: [
              bytesAsync.when(
                data: (bytes) => Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  cacheWidth: (constraints.maxWidth * dpr).ceil(),
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: AppColors.background,
                    child: Icon(Icons.broken_image_outlined, color: AppColors.textMuted),
                  ),
                ),
                loading: () => const ColoredBox(
                  color: AppColors.background,
                  child: Center(
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                ),
                error: (e, st) => const ColoredBox(
                  color: AppColors.background,
                  child: Icon(Icons.broken_image_outlined, color: AppColors.textMuted),
                ),
              ),
              Positioned(
                left: 4,
                bottom: 4,
                child: StatusRegistry.build(photo.stage, StatusRegistry.photoStage),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoViewerScreen extends ConsumerWidget {
  const _PhotoViewerScreen({required this.projectId, required this.photo, required this.canManage});
  final String projectId;
  final ProjectPhoto photo;
  final bool canManage;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
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
      unawaited(ref.read(projectPhotoCacheProvider).remove(photo.id));
      ref.invalidate(projectPhotosProvider(projectId));
      if (context.mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytesAsync = ref.watch(projectPhotoBytesProvider((projectId: projectId, photoId: photo.id)));
    final description = photo.description.trim();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(photo.originalName, style: const TextStyle(fontSize: 14)),
        actions: [
          if (canManage)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Fotoğrafı sil',
              onPressed: () => _delete(context, ref),
            ),
        ],
      ),
      body: Center(
        child: bytesAsync.when(
          // Tam ekran: ekranın ~2 katı genişlikte çözülür (yakınlaştırmaya
          // yeter; 12 MP'yi tam açıp yüzlerce MB harcamaz).
          data: (bytes) => InteractiveViewer(
            child: Image.memory(
              bytes,
              cacheWidth: (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context) * 2).ceil(),
            ),
          ),
          loading: () => const CircularProgressIndicator(color: Colors.white),
          error: (e, st) => const Icon(Icons.broken_image_outlined, color: Colors.white, size: 48),
        ),
      ),
      // Aşama, tarih, tam açıklama ve görünür bir "Sil" -- silme eskiden
      // yalnızca ızgarada uzun basışla (keşfedilemez) ya da etiketsiz bir
      // simgeyle yapılabiliyordu.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              StatusRegistry.build(photo.stage, StatusRegistry.photoStage),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (description.isNotEmpty)
                      Text(
                        description,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    Text(
                      Formatters.dateTime(photo.createdAt),
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (canManage)
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: () => _delete(context, ref),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Sil'),
                ),
            ],
          ),
        ),
      ),
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
    // Değer kendi genişliğini alır (en çok satırın %70'i), etiket KALAN tüm
    // genişliği: sabit 2/5 etiket sütunu, değer kısa olsa bile 360 dp'de
    // "Satış / Sözleşm..." / "Gerçekleşen Ma..." diye kesiyordu.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: AppSpacing.sm),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.7),
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
                            style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5),
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

