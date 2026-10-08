import 'package:flutter/material.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/status_badge.dart';
import '../../auth/domain/user.dart';
import 'dashboard.dart';
import 'mobile_routes.dart';

/// Ana sayfa kayıt defteri -- web `lib/dashboard.ts` ile AYNI algoritmalar
/// (modül/bant sırası, KPI seçimi, ikincil panel, dikkat başlıkları,
/// özet cümlesi, iskelet tahmini) ve AYNI Türkçe metinler (spec §7).
/// Burada yalnızca SAF fonksiyonlar vardır; hiçbiri para toplamaz ya da
/// yeniden hesaplamaz (spec D1) -- sunucunun verdiği sayıları seçer ve
/// biçimler.

// ---------- Modüller ve bantlar ----------

enum ModuleKey {
  finance('finance'),
  offers('offers'),
  changeOrders('change_orders'),
  projects('projects'),
  tasks('tasks'),
  operations('operations'),
  contracts('contracts'),
  attendance('attendance'),
  procurement('procurement'),
  subcontracts('subcontracts'),
  costControl('cost_control'),
  customers('customers'),
  employees('employees'),
  products('products'),
  users('users'),
  calculations('calculations'),
  suppliers('suppliers'),
  costCodes('cost_codes');

  const ModuleKey(this.wire);

  /// JSON bölüm anahtarı.
  final String wire;

  static ModuleKey? fromWire(String value) {
    for (final m in values) {
      if (m.wire == value) return m;
    }
    return null;
  }
}

/// Modül kartının mobil hedefi: sekme kökleri `go` (dal değişir), Diğer
/// altındaki ekranlar `push`.
class ModuleRoute {
  const ModuleRoute(this.path, {this.push = false});
  final String path;
  final bool push;
}

enum BandKey { cashSales, projectField, supplyCost, registry }

class ModuleDef {
  const ModuleDef({
    required this.key,
    required this.title,
    required this.icon,
    required this.band,
    this.compact = false,
    this.route,
    this.projectBound = false,
  });

  final ModuleKey key;
  final String title;
  final IconData icon;
  final BandKey band;

  /// Web'de tek satırlık kompakt kart (Metraj/Tedarikçiler/Maliyet Kodları).
  final bool compact;

  /// null = mobilde ekranı yok (kart/satır dokunulamaz).
  final ModuleRoute? route;

  /// Kurulum modunda tek "Proje modülleri" kartına katlanan 9 modül.
  final bool projectBound;

  /// Mobilde FİRMA KAYITLARI tek bir gruplu kartta satır olarak çizilir.
  bool get isRegistry => band == BandKey.registry;
}

const _projectsRoute = ModuleRoute('/projeler');

const kModules = <ModuleKey, ModuleDef>{
  ModuleKey.finance: ModuleDef(
    key: ModuleKey.finance,
    title: 'Proje Finansı',
    icon: Icons.account_balance_wallet_outlined,
    band: BandKey.cashSales,
    route: _projectsRoute,
    projectBound: true,
  ),
  ModuleKey.offers: ModuleDef(
    key: ModuleKey.offers,
    title: 'Teklifler',
    icon: Icons.request_quote_outlined,
    band: BandKey.cashSales,
    route: ModuleRoute('/teklifler'),
  ),
  ModuleKey.changeOrders: ModuleDef(
    key: ModuleKey.changeOrders,
    title: 'Ek İşler',
    icon: Icons.note_add_outlined,
    band: BandKey.cashSales,
    route: _projectsRoute,
    projectBound: true,
  ),
  ModuleKey.projects: ModuleDef(
    key: ModuleKey.projects,
    title: 'Projeler',
    icon: Icons.apartment_outlined,
    band: BandKey.projectField,
    route: _projectsRoute,
    projectBound: true,
  ),
  ModuleKey.tasks: ModuleDef(
    key: ModuleKey.tasks,
    title: 'Görevler',
    icon: Icons.checklist,
    band: BandKey.projectField,
    route: ModuleRoute('/gorevler'),
    projectBound: true,
  ),
  ModuleKey.operations: ModuleDef(
    key: ModuleKey.operations,
    title: 'Şantiye',
    icon: Icons.construction,
    band: BandKey.projectField,
    route: _projectsRoute,
    projectBound: true,
  ),
  ModuleKey.contracts: ModuleDef(
    key: ModuleKey.contracts,
    title: 'Sözleşmeler',
    icon: Icons.gavel_outlined,
    band: BandKey.projectField,
    route: _projectsRoute,
    projectBound: true,
  ),
  ModuleKey.attendance: ModuleDef(
    key: ModuleKey.attendance,
    title: 'Mesai / Puantaj',
    icon: Icons.schedule,
    band: BandKey.projectField,
    route: ModuleRoute('/diger/mesai', push: true),
  ),
  ModuleKey.procurement: ModuleDef(
    key: ModuleKey.procurement,
    title: 'Satın Alma',
    icon: Icons.shopping_cart_outlined,
    band: BandKey.supplyCost,
    route: _projectsRoute,
    projectBound: true,
  ),
  ModuleKey.subcontracts: ModuleDef(
    key: ModuleKey.subcontracts,
    title: 'Taşeron',
    icon: Icons.handshake_outlined,
    band: BandKey.supplyCost,
    route: _projectsRoute,
    projectBound: true,
  ),
  ModuleKey.costControl: ModuleDef(
    key: ModuleKey.costControl,
    title: 'Bütçe & Maliyet',
    icon: Icons.balance,
    band: BandKey.supplyCost,
    route: _projectsRoute,
    projectBound: true,
  ),
  ModuleKey.customers: ModuleDef(
    key: ModuleKey.customers,
    title: 'Müşteriler',
    icon: Icons.people_outline,
    band: BandKey.registry,
    route: ModuleRoute('/diger/musteriler', push: true),
  ),
  // Firma kayıtları -- web kartının hedefiyle aynı ekran (spec §2 #13-18):
  // Personel /admin/personel, Ürünler & Zam /admin/urunler/zamlar?period=30,
  // Ekip /admin/kullanicilar, Tedarikçiler, Maliyet Kodları. Hedef ekranlar
  // kendi iznini (katı canAccess) ayrıca denetler; satır yalnızca sunucu
  // bölümü döndürdüyse (= izin var) çizilir.
  ModuleKey.employees: ModuleDef(
    key: ModuleKey.employees,
    title: 'Personel',
    icon: Icons.engineering_outlined,
    band: BandKey.registry,
    route: ModuleRoute('/diger/personel', push: true),
  ),
  ModuleKey.products: ModuleDef(
    key: ModuleKey.products,
    title: 'Ürünler & Zam',
    icon: Icons.inventory_2_outlined,
    band: BandKey.registry,
    route: ModuleRoute('/diger/urunler/zamlar?period=30', push: true),
  ),
  ModuleKey.users: ModuleDef(
    key: ModuleKey.users,
    title: 'Ekip',
    icon: Icons.manage_accounts_outlined,
    band: BandKey.registry,
    route: ModuleRoute('/diger/kullanicilar', push: true),
  ),
  ModuleKey.calculations: ModuleDef(
    key: ModuleKey.calculations,
    title: 'Metraj',
    icon: Icons.straighten,
    band: BandKey.registry,
    compact: true,
    // Kartın içeriği reçete durumu (grup/kategori, ürüne bağlanmamış kalem):
    // web'deki gibi reçete yönetimine gider. Hesap makinesi "Metraj Hesapla"
    // hızlı işleminden açılır (/diger/metraj).
    route: ModuleRoute('/diger/metraj-receteleri', push: true),
  ),
  ModuleKey.suppliers: ModuleDef(
    key: ModuleKey.suppliers,
    title: 'Tedarikçiler',
    icon: Icons.local_shipping_outlined,
    band: BandKey.registry,
    compact: true,
    route: ModuleRoute('/diger/tedarikciler', push: true),
  ),
  ModuleKey.costCodes: ModuleDef(
    key: ModuleKey.costCodes,
    title: 'Maliyet Kodları',
    icon: Icons.sell_outlined,
    band: BandKey.registry,
    compact: true,
    route: ModuleRoute('/diger/maliyet-kodlari', push: true),
  ),
};

class BandDef {
  const BandDef({required this.key, required this.title, required this.modules});
  final BandKey key;

  /// Mobil bant başlığı -- BİLEREK büyük harfle yazılmış sabit
  /// (`toUpperCase()` Türkçe "i"yi bozar, spec §6.4).
  final String title;

  /// Sabit sıra; veriye göre ASLA değişmez (spec §1.3).
  final List<ModuleKey> modules;
}

const kBands = <BandDef>[
  BandDef(
    key: BandKey.cashSales,
    title: 'NAKİT & SATIŞ',
    modules: [ModuleKey.finance, ModuleKey.offers, ModuleKey.changeOrders],
  ),
  BandDef(
    key: BandKey.projectField,
    title: 'PROJE & SAHA',
    modules: [ModuleKey.projects, ModuleKey.tasks, ModuleKey.operations, ModuleKey.contracts, ModuleKey.attendance],
  ),
  BandDef(
    key: BandKey.supplyCost,
    title: 'TEDARİK & MALİYET',
    modules: [ModuleKey.procurement, ModuleKey.subcontracts, ModuleKey.costControl],
  ),
  BandDef(
    key: BandKey.registry,
    title: 'FİRMA KAYITLARI',
    modules: [
      ModuleKey.customers,
      ModuleKey.employees,
      ModuleKey.products,
      ModuleKey.users,
      ModuleKey.calculations,
      ModuleKey.suppliers,
      ModuleKey.costCodes,
    ],
  ),
];

const kDensityBandTitle = 'BÖLÜMLER';

/// Kurulum modundaki sabit sıra (spec §3.6): yer tutucu, sonra bunlar.
const _onboardingOrder = <ModuleKey>[
  ModuleKey.offers,
  ModuleKey.attendance,
  ModuleKey.customers,
  ModuleKey.employees,
  ModuleKey.products,
  ModuleKey.users,
  ModuleKey.calculations,
  ModuleKey.suppliers,
  ModuleKey.costCodes,
];

/// Bir bant: standart kartlar + kompakt kartlar (web'deki ayrım; mobil
/// FİRMA KAYITLARI modüllerini ayrıca tek gruplu karta toplar).
class LayoutBand {
  const LayoutBand({
    required this.title,
    required this.standard,
    required this.compact,
    this.placeholder = false,
    this.density = false,
  });

  final String title;
  final List<ModuleKey> standard;
  final List<ModuleKey> compact;

  /// Kurulum modunun "Proje modülleri" yer tutucusu bandın başında.
  final bool placeholder;

  /// Tek "BÖLÜMLER" ızgarası (≤5 standart kart ya da kurulum modu).
  final bool density;

  List<ModuleKey> get all => [...standard, ...compact];
}

/// Kartı çizilecek modüller: bölümü gelen YA DA izni olup o an
/// hesaplanamayan (section_errors -- kart başlığıyla hata gösterir).
Set<ModuleKey> visibleModules(Dashboard d) => {
  for (final m in ModuleKey.values)
    if (d.sections.has(m.wire) || d.sectionErrors.contains(m.wire)) m,
};

bool onboardingActive(Dashboard d, {required bool hidden}) => d.onboarding != null && !hidden;

/// Ana sayfada KART OLARAK GÖSTERİLMEYEN boş modül: kartı yalnızca boş
/// durum cümlesini ("Henüz taşeron sözleşmesi yok." vb.) gösterecekti ve
/// bekleyen dikkat grubu yok. Koşullar kartların kendi boş durumlarıyla
/// BİREBİR aynıdır (presentation/widgets/module_cards.dart,
/// records_group_card.dart). Görevler kartının boş durumu yok; her sayısı
/// sıfırsa boş sayılır.
///
/// Neden: küçük bir firma modüllerin çoğunu kullanmıyor; sahadaki ana
/// sayfa (2026-10) boş kartlar ve tekrar eden "Bekleyen iş yok"
/// satırlarıyla ekranlarca uzuyor, işe yarayan kart aralarında
/// kayboluyordu. Boş modüller sayfanın sonunda tek satırda listelenir
/// (bkz. idleModules) -- hiçbiri erişilemez olmaz.
///
/// Hesaplanamayan (section_errors) bölüm boş SAYILMAZ: hata kartı görünmeli.
bool moduleIdle(Dashboard d, ModuleKey m) {
  if (d.sectionErrors.contains(m.wire) || !d.sections.has(m.wire)) return false;
  if (moduleGroups(d, m).isNotEmpty) return false;
  final s = d.sections;
  switch (m) {
    case ModuleKey.finance:
      return s.finance!.byCurrency.isEmpty;
    case ModuleKey.offers:
      return s.offers!.totalActive == 0;
    case ModuleKey.changeOrders:
      return s.changeOrders!.byCurrency.isEmpty;
    case ModuleKey.projects:
      return s.projects!.counts.total == 0;
    case ModuleKey.tasks:
      final t = s.tasks!;
      return t.mine.open + t.mine.overdue + t.mine.dueToday == 0 &&
          t.team.open + t.team.overdue + t.team.unassigned + t.team.completed7d == 0;
    case ModuleKey.operations:
      final o = s.operations!;
      return o.activeCrew == 0 && o.milestonesDue7d == 0 && o.milestonesOverdue == 0 && o.photos7d == 0;
    case ModuleKey.contracts:
      final k = s.contracts!;
      return k.draft + k.active + k.completed + k.cancelled + k.terminated == 0 &&
          k.activeProjectsWithoutContract == 0;
    case ModuleKey.attendance:
      return s.attendance!.activeEmployees == 0;
    case ModuleKey.procurement:
      final p = s.procurement!;
      return p.prDraft + p.prSubmitted + p.rfqIssued + p.poDraft + p.poApprovedOpen == 0 &&
          p.approvedThisMonth.isEmpty;
    case ModuleKey.subcontracts:
      final c = s.subcontracts!;
      return c.activeCount == 0 && c.byCurrency.isEmpty;
    case ModuleKey.costControl:
      final k = s.costControl!;
      final b = k.budgets;
      final noBudgets = b != null && b.draft + b.baselined == 0;
      return noBudgets && (k.overBudget?.count ?? 0) == 0 && (k.committedActive?.isEmpty ?? true);
    case ModuleKey.customers:
      final v = s.customers!;
      return v.active == 0 && v.newThisMonth == 0;
    case ModuleKey.employees:
      final v = s.employees!;
      return v.active + v.inactive == 0;
    case ModuleKey.products:
      return s.products!.total == 0;
    case ModuleKey.users:
      return s.users!.active <= 1;
    case ModuleKey.calculations:
      return s.calculations!.groups == 0;
    case ModuleKey.suppliers:
      final v = s.suppliers!;
      return v.active + v.inactive == 0;
    case ModuleKey.costCodes:
      final v = s.costCodes!;
      return v.active + v.inactive == 0;
  }
}

/// Kart olarak çizilmeyen boş modüller, bant sırasıyla (sayfa sonundaki
/// "Henüz kullanılmayan bölümler" satırı). Kurulum modunda boş: orada boş
/// durum cümleleri kurulum rehberinin parçası, kartlar olduğu gibi kalır.
List<ModuleKey> idleModules(Dashboard d, {required bool onboardingActive}) {
  if (onboardingActive) return const [];
  return [
    for (final b in kBands)
      for (final m in b.modules)
        if (moduleIdle(d, m)) m,
  ];
}

List<LayoutBand> layoutBands(Dashboard d, {required bool onboardingActive}) {
  var visible = visibleModules(d);
  if (onboardingActive) {
    final ordered = [
      for (final m in _onboardingOrder)
        if (visible.contains(m)) m,
    ];
    return [
      LayoutBand(
        title: kDensityBandTitle,
        standard: [
          for (final m in ordered)
            if (!kModules[m]!.compact) m,
        ],
        compact: [
          for (final m in ordered)
            if (kModules[m]!.compact) m,
        ],
        placeholder: visible.any((m) => kModules[m]!.projectBound),
        density: true,
      ),
    ];
  }

  final idle = idleModules(d, onboardingActive: false).toSet();
  visible = visible.difference(idle);
  final canonical = [for (final b in kBands) ...b.modules];
  final standardCount = visible.where((m) => !kModules[m]!.compact).length;
  if (standardCount <= 5) {
    final ordered = [
      for (final m in canonical)
        if (visible.contains(m)) m,
    ];
    if (ordered.isEmpty) return const [];
    return [
      LayoutBand(
        title: kDensityBandTitle,
        standard: [
          for (final m in ordered)
            if (!kModules[m]!.compact) m,
        ],
        compact: [
          for (final m in ordered)
            if (kModules[m]!.compact) m,
        ],
        density: true,
      ),
    ];
  }

  return [
    for (final band in kBands)
      if (band.modules.any(visible.contains))
        LayoutBand(
          title: band.title,
          standard: [
            for (final m in band.modules)
              if (visible.contains(m) && !kModules[m]!.compact) m,
          ],
          compact: [
            for (final m in band.modules)
              if (visible.contains(m) && kModules[m]!.compact) m,
          ],
        ),
  ];
}

// ---------- KPI (Nabız) ----------

enum KpiKey { receivable, netCash, pipeline, cashBalance, activeProjects, myTasks, teamOverdue, onSite, unread }

/// İlk 4 uygun aday (spec §3.3). Satır, 2'den az aday varsa çizilmez --
/// bu kararı çağıran verir.
List<KpiKey> pickKpis(Dashboard d) {
  final s = d.sections;
  final hasFinance = (s.finance?.byCurrency.isNotEmpty) ?? false;
  final available = <KpiKey>[
    if (hasFinance) KpiKey.receivable,
    if (hasFinance) KpiKey.netCash,
    if ((s.offers?.byCurrency.isNotEmpty) ?? false) KpiKey.pipeline,
    if (hasFinance) KpiKey.cashBalance,
    if (s.projects != null) KpiKey.activeProjects,
    if (s.tasks?.mine.linkedEmployee ?? false) KpiKey.myTasks,
    if (s.tasks != null) KpiKey.teamOverdue,
    if (s.attendance != null) KpiKey.onSite,
    if (s.notifications != null) KpiKey.unread,
  ];
  return available.take(4).toList();
}

enum SecondaryPanel { cash, myTasks, none }

/// Üst sıradaki ikinci panel: finans varsa Nakit Akışı, yoksa personele
/// bağlı kullanıcıda Görevlerim, yoksa hiçbiri (spec §1.1). Finans izni
/// olup bölüm o an hesaplanamadıysa (section_errors) da Nakit Akışı kalır
/// ve hata gövdesiyle çizilir (spec §6.7) -- geçici bir sunucu hatası
/// sayfanın üst düzenini değiştirmesin.
SecondaryPanel secondaryPanel(Dashboard d) {
  if (d.sections.finance != null || d.sectionErrors.contains('finance')) return SecondaryPanel.cash;
  if (d.sections.tasks?.mine.linkedEmployee ?? false) return SecondaryPanel.myTasks;
  return SecondaryPanel.none;
}

// ---------- Dikkat Gerektirenler ----------

const kLaneMineLabel = 'SENİN SIRAN';
const kLaneWatchingLabel = 'TAKİPTE';
const kLaneUpcomingLabel = 'YAKLAŞAN · 14 GÜN';

/// Modüle ait dikkat grupları, sunucunun sıralamasıyla.
List<AttentionGroup> moduleGroups(Dashboard d, ModuleKey key) => [
  for (final g in d.agenda.groups)
    if (g.module == key.wire) g,
];

String _kaynak(AttentionGroup g) {
  final names = [for (final r in g.items) _recordLabel(r)];
  return names.isEmpty ? 'Tedarikçi' : names.join(' ve ');
}

/// Kaydın etiketi; fiyat kaynağında sabit kısa ad ("Ulaş" / "Demir Profil").
String _recordLabel(AttentionRecord r) {
  if (r.ref.kind == 'price_source' && (r.ref.id == 'ulas' || r.ref.id == 'demirprofil')) {
    return priceSourceName(r.ref.id);
  }
  return r.label.isNotEmpty ? r.label : priceSourceName(r.ref.id);
}

String priceSourceName(String source) => switch (source) {
  'ulas' => 'Ulaş',
  'demirprofil' => 'Demir Profil',
  _ => source,
};

/// Grup başlığı (Dikkat satırı ve kart alt satırı). Türkçede sayıdan
/// sonra isim tekil kalır; tek şablon her sayıya uyar (spec §3.1).
String attentionTitle(AttentionGroup g) {
  final n = g.count;
  return switch (g.code) {
    'plan_item_overdue' => '$n ödeme planı kaleminin vadesi geçti',
    'sales_invoice_overdue' => '$n satış faturasının vadesi geçti',
    'expense_approval' => '$n masraf onay bekliyor',
    'change_order_awaiting_customer' => '$n ek iş müşteri onayında',
    'offer_expired_awaiting' => '$n teklifin süresi doldu, müşteri yanıt vermedi',
    'offer_accepted_not_converted' => '$n kabul edilen teklif projeye dönüştürülmedi',
    'purchase_request_approval' => '$n satın alma talebi onay bekliyor',
    'purchase_order_draft' => '$n sipariş taslağı onaylanmadı',
    'rfq_award' => "$n RFQ'da teklifler toplandı, karar bekliyor",
    'rfq_no_quote' => "$n RFQ'nun süresi doldu, teklif gelmedi",
    'po_late_delivery' => '$n siparişin teslimi gecikti',
    'progress_claim_certify' => '$n taşeron hakedişi onay bekliyor',
    'claim_certified_unpaid' => '$n onaylı hakedişin ödemesi yapılmadı',
    'subcontract_co_approval' => '$n taşeron değişiklik emri onay bekliyor',
    'budget_adjustment_approval' => '$n bütçe revizyonu onay bekliyor',
    'over_budget' => '$n proje bütçesini aştı',
    'active_without_budget' => '$n aktif projenin onaylı bütçesi yok',
    'contract_activation' => '$n sözleşme taslakta, aktifleştirilmedi',
    'contract_past_completion' => '$n sözleşmenin planlanan bitişi geçti',
    'active_without_contract' => '$n aktif projenin sözleşme kaydı yok',
    'project_past_end' => '$n projenin bitiş tarihi geçti',
    'my_task_overdue' => '$n görevin gecikti',
    'my_task_due_today' => '$n görevin bugün bitiyor',
    'team_task_overdue' => 'Ekipte $n görev gecikmiş',
    'team_task_unassigned' => '$n görev kimseye atanmamış',
    'milestone_overdue' => '$n iş programı kalemi gecikti',
    'attendance_not_recorded' => 'Bugün $n personelin mesaisi girilmedi',
    'price_sync_failed' => '${_kaynak(g)} fiyat senkronu başarısız oldu',
    'price_sync_never' => '${_kaynak(g)} fiyat kaynağı hiç senkronlanmadı',
    'users_without_project' => '$n kullanıcı hiçbir projeyi göremiyor',
    // Tanınmayan kod -- sürüm farkında çökmek yerine genel metin.
    _ => '$n kayıt dikkat gerektiriyor',
  };
}

/// Tek kaydın satırı (spec §3.1 "record line"). `label` kaydın kendi
/// metnidir; proje düzeyindeki kodlarda "{project}" proje adıdır.
String attentionRecordLine(AttentionRecord r, String code) {
  // web `attentionRecordLine` ile AYNI kural: kaydın etiketi + (etikette
  // zaten yoksa) proje adı + koda göre gün ifadesi ya da aşım yüzdesi.
  // Tutar ayrı gösterilir.
  final label = _recordLabel(r);
  final project = r.projectName;
  final parts = <String>[
    if (label.isNotEmpty) label,
    if (project != null && project.isNotEmpty && !label.contains(project)) project,
  ];
  final days = r.days;
  final phrase = _daysPhrase[code];
  if (code == 'over_budget' && r.pct != null) {
    parts.add('${Formatters.percent(r.pct!)}${kNbsp}aşım');
  } else if (days != null && phrase != null) {
    parts.add(phrase(days));
  }
  return parts.join(' · ');
}

// Sayı ile "gün" arasında bölünmez boşluk: dar satırda "13" bir satırda,
// "gün gecikti" diğerinde kalmaz.
String _late(int d) => '$d${kNbsp}gün gecikti';
String _waiting(int d) => '$d${kNbsp}gündür bekliyor';
String _passed(int d) => '$d${kNbsp}gün geçti';

/// 0 -> "bugün", 1 -> "dün", n -> "n gün önce".
String relativeDays(int days) {
  if (days <= 0) return 'bugün';
  if (days == 1) return 'dün';
  return '$days${kNbsp}gün önce';
}

/// Kaydın gün sayısının satırdaki okunuşu (koda göre, spec §3.1).
const _daysPhrase = <String, String Function(int)>{
  'plan_item_overdue': _late,
  'sales_invoice_overdue': _late,
  'po_late_delivery': _late,
  'my_task_overdue': _late,
  'team_task_overdue': _late,
  'milestone_overdue': _late,
  'change_order_awaiting_customer': _waiting,
  'purchase_request_approval': _waiting,
  'progress_claim_certify': _waiting,
  'budget_adjustment_approval': _waiting,
  'expense_approval': _waiting,
  'offer_expired_awaiting': _expired,
  'rfq_no_quote': _passed,
  'contract_past_completion': _passed,
  'project_past_end': _passed,
  'price_sync_failed': relativeDays,
};

String _expired(int d) => '$d${kNbsp}gün önce doldu';

/// Grup satırının ikinci satırı: tek kayıtta kaydın kendisi, çoklu
/// grupta "850.000 TL · en eski 21 gün".
String attentionMeta(AttentionGroup g) {
  // Satırlarda TAM tutar (spec D5); birincil dışı para birimleri "Diğer: …".
  if (g.count == 1 && g.items.isNotEmpty) {
    final r = g.items.first;
    return [
      attentionRecordLine(r, g.code),
      if (r.amount != null) Formatters.money(r.amount!.amount, currency: r.amount!.currency),
    ].join(' · ');
  }
  return [
    if (g.amounts.isNotEmpty) Formatters.money(g.amounts.first.amount, currency: g.amounts.first.currency),
    if ((g.oldestDays ?? 0) > 0) 'en eski ${g.oldestDays}${kNbsp}gün',
    if (g.amounts.length > 1)
      'Diğer: ${g.amounts.skip(1).map((a) => Formatters.money(a.amount, currency: a.currency)).join(' · ')}',
  ].join(' · ');
}

/// Modül başlığındaki çip: danger > action > info (spec §3.1). Mobilde
/// "action" gold DEĞİL warning'dir (gold bir durum rengi değildir, D7).
(String, StatusTone)? attentionChip(List<AttentionGroup> groups) {
  int sum(String severity) => groups.where((g) => g.severity == severity).fold(0, (total, g) => total + g.count);
  final danger = sum('danger');
  if (danger > 0) return ('$danger uyarı', StatusTone.danger);
  final action = sum('action');
  if (action > 0) return ('$action bekliyor', StatusTone.warning);
  final info = sum('info');
  if (info > 0) return ('$info takipte', StatusTone.info);
  return null;
}

String upcomingLabel(String kind) => switch (kind) {
  'plan_item_due' => 'Ödeme planı',
  'offer_expiry' => 'Teklif süresi doluyor',
  'po_delivery' => 'Sipariş teslimi',
  'milestone_end' => 'İş programı',
  'project_end' => 'Proje bitişi',
  'my_task_due' => 'Görev',
  _ => 'Yaklaşan',
};

/// "YYYY-MM-DD" + gün (takvim aritmetiği; saat dilimi yok).
String addDays(String isoDate, int days) {
  final parsed = DateTime.tryParse(isoDate);
  if (parsed == null) return isoDate;
  final d = DateTime.utc(parsed.year, parsed.month, parsed.day).add(Duration(days: days));
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// "Bugün" / "Yarın" / "30 Eyl" -- "bugün" sunucunun İstanbul `today`'idir.
String upcomingDateLabel(String date, String today) {
  if (date == today) return 'Bugün';
  if (date == addDays(today, 1)) return 'Yarın';
  return Formatters.shortDayMonth(date);
}

/// Dikkat kartındaki "Tümü (n)": şeritlerdeki iş sayıları + yaklaşanlar.
int attentionTotal(DashboardAgenda a) => a.mineCount + a.watchingCount + a.upcoming.length;

// ---------- Özet cümlesi / kapsam satırı ----------

String summarySentence(DashboardAgenda a) {
  if (a.mineCount > 0) {
    final tail = a.mineDangerCount > 0 ? '; ${a.mineDangerCount} tanesi acil.' : '.';
    return 'Bugün ${a.mineCount} iş senin sıranda$tail';
  }
  if (a.watchingCount > 0) return 'Senin sıranda iş yok; ${a.watchingCount} konu takipte.';
  return 'Bugün seni bekleyen bir iş yok.';
}

/// Yalnızca üyelikle kısıtlı kullanıcıda (viewer.all_projects == false).
String? scopeLine(DashboardViewer v) {
  if (v.allProjects) return null;
  if (v.accessibleProjectCount == 0) {
    return 'Henüz bir projeye eklenmedin; yöneticin seni eklediğinde proje verileri burada görünür.';
  }
  return 'Üyesi olduğun ${v.accessibleProjectCount} projenin verileri gösteriliyor.';
}

// ---------- Hızlı işlemler ----------

enum QuickActionKey {
  offer('Teklif Oluştur', Icons.description_outlined, ['offers.create'], needsProject: false),
  collection('Tahsilat Gir', Icons.payments_outlined, ['projects.finance.manage']),
  // Herkes masraf girer, onay bekler (backend migration 0066); finans
  // izni gerekmez. "Masraf Takibi" Masraflarım ekranını açar -- kısa ad:
  // 360 dp'lik telefonda "Masraflarım" kutucukta hecesinden bölünüyordu.
  // "Masraf Gir" ayrıca projects.read ister: 0066 masraf iznini ÖZEL roller
  // dahil her role verdi, proje seçici (/dashboard/project-options) ise
  // projects.read ister -- projeleri göremeyen her dokunuşta hata alıyordu.
  expense('Masraf Gir', Icons.receipt_long_outlined, ['projects.expenses.create', 'projects.read']),
  myExpenses('Masraf Takibi', Icons.fact_check_outlined, ['projects.expenses.create'], needsProject: false),
  attendance('Mesai Gir', Icons.more_time, ['attendance.manage', 'employees.read'], needsProject: false),
  // Kısa ad: eşit genişlikli kutucukta "Satın Alma Talebi" "Satın Alma Ta…" diye kesiliyordu.
  purchaseRequest('Satın Alma', Icons.shopping_cart_outlined, ['projects.procurement.manage']),
  task('Görev Ekle', Icons.add_task, ['projects.tasks.create']),
  note('Not Ekle', Icons.sticky_note_2_outlined, ['projects.operations.manage']),
  customer('Müşteri Ekle', Icons.person_add_alt_outlined, ['customers.manage'], needsProject: false),
  calc('Metraj Hesapla', Icons.calculate_outlined, ['calculations.read'], needsProject: false);

  const QuickActionKey(this.label, this.icon, this.permissions, {this.needsProject = true});

  final String label;
  final IconData icon;

  /// HEPSİ gerekir (ör. Mesai Gir = attendance.manage VE employees.read).
  final List<String> permissions;
  final bool needsProject;
}

/// Sabit sırada, izne göre süzülmüş hızlı işlemler (spec §3.5). Yeni Proje
/// YOK -- projeler yalnızca tekliften dönüşümle açılır.
List<QuickActionKey> quickActionsFor(User? user) => [
  for (final a in QuickActionKey.values)
    if (user.canAll(a.permissions)) a,
];

/// Yönetim ekranlarına giden boş durum / kurulum CTA'ları -- web
/// `ONBOARDING_STEPS` ve modül kartlarının boş durum CTA'larıyla AYNI hedef
/// ve AYNI kapı (web quickActionGate). Kapı KATI `canAccess` ile denetlenir
/// (fail-closed; Kullanıcı Ekle ayrıca kaba rol admin ister).
class AdminCta {
  const AdminCta(this.label, this.route, this.permissions);

  final String label;
  final String route;

  /// HEPSİ gerekir.
  final List<String> permissions;

  bool allowedFor(User? user) => permissions.every((code) => user.canAccess(code));
}

const kCtaProducts = AdminCta('Ürünlere git', '/diger/urunler', ['products.read']);
const kCtaAddEmployee = AdminCta('Personel Ekle', '/diger/personel/yeni', ['employees.read', 'employees.manage']);
const kCtaAddUser = AdminCta('Kullanıcı Ekle', '/diger/kullanicilar/yeni', [
  'organization.users.read',
  'organization.users.manage',
  'organization.roles.read',
]);

// ---------- İskelet tahmini ----------

/// Sunucunun bölüm kapılarının istemci tahmini (yalnızca yükleniyor
/// iskeleti için). İzin kümesi boşsa (eski oturum) null -> genel iskelet.
Set<String>? predictSections(User? user) {
  if (user == null || user.permissions.isEmpty) return null;
  bool has(String code) => user.hasPermission(code);
  return {
    if (has('projects.read')) 'projects',
    if (has('projects.finance.read')) ...['finance', 'change_orders'],
    if (has('offers.read')) 'offers',
    if (has('projects.procurement.read')) 'procurement',
    if (has('projects.subcontracts.read')) 'subcontracts',
    if (has('projects.budget.read') || has('projects.cost_control.read')) 'cost_control',
    if (has('projects.contracts.read')) 'contracts',
    if (has('projects.tasks.read')) 'tasks',
    if (has('projects.operations.read')) 'operations',
    if (has('attendance.read')) 'attendance',
    if (has('employees.read')) 'employees',
    if (has('customers.read')) 'customers',
    if (has('products.read')) 'products',
    if (user.role == UserRole.admin && has('organization.users.read')) 'users',
    if (has('calculations.read')) 'calculations',
    if (has('organization.suppliers.read')) 'suppliers',
    if (has('organization.cost_codes.read')) 'cost_codes',
    if (has('notifications.read')) 'notifications',
    'activity',
  };
}

// ---------- Kurulum adımları ----------

class OnboardingStepCopy {
  const OnboardingStepCopy(this.title, {this.helper});
  final String title;
  final String? helper;
}

const kOnboardingSteps = <String, OnboardingStepCopy>{
  'customer': OnboardingStepCopy('İlk müşterini ekle'),
  'catalog': OnboardingStepCopy(
    'Ürün kataloğunu hazırla',
    helper: "Ulaş veya Demir Profil'den çekebilir ya da elle ekleyebilirsin.",
  ),
  'employee': OnboardingStepCopy('Personel ekle'),
  'team': OnboardingStepCopy('Ekibini davet et'),
  'first_offer': OnboardingStepCopy('İlk teklifini hazırla'),
  'convert': OnboardingStepCopy(
    'Kabul edilen teklifi projeye dönüştür',
    helper: 'Müşteri teklifi kabul edince tek tıkla proje açılır.',
  ),
};

// ---------- Ortak metinler ----------

const kMonthShort = ['Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz', 'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara'];
const kMonthLong = [
  'Ocak',
  'Şubat',
  'Mart',
  'Nisan',
  'Mayıs',
  'Haziran',
  'Temmuz',
  'Ağustos',
  'Eylül',
  'Ekim',
  'Kasım',
  'Aralık',
];

/// "2026-04" -> (Nis, Nisan 2026).
(String, String) monthLabels(String yearMonth) {
  final parts = yearMonth.split('-');
  final month = parts.length > 1 ? int.tryParse(parts[1]) : null;
  if (month == null || month < 1 || month > 12) return (yearMonth, yearMonth);
  return (kMonthShort[month - 1], '${kMonthLong[month - 1]} ${parts[0]}');
}

/// Grup satırına dokununca gidilecek yer: tek kayıt -> kaydın ekranı (yoksa
/// modül ekranı), çoklu -> Dikkat listesi o kod açık. Hiçbiri yoksa null.
ModuleRoute? attentionGroupTarget(AttentionGroup g) {
  // Kaydı olmayan grup (ör. mesai girilmedi) modül ekranına gider.
  if (g.items.isEmpty) return moduleRouteFor(g.module);
  if (g.count > 1) {
    return ModuleRoute('/ana-sayfa/dikkat?kod=${Uri.encodeQueryComponent(g.code)}', push: true);
  }
  final record = mobileRouteFor(g.items.first.ref);
  if (record != null) return ModuleRoute(record, push: true);
  return moduleRouteFor(g.module);
}

/// Modülün mobil ekranı (yoksa null).
ModuleRoute? moduleRouteFor(String moduleWire) {
  final module = ModuleKey.fromWire(moduleWire);
  return module == null ? null : kModules[module]!.route;
}

const kCopySectionError = 'Bu özet şu an yüklenemedi.';
const kCopyRetry = 'Tekrar dene';
const kCopyQuiet = 'Bekleyen iş yok';
const kCopyDikkatEmpty = 'Her şey yolunda — seni bekleyen onay ya da gecikme yok.';
const kCopyDikkatPartial = 'Bazı bölümler yüklenemedi; liste eksik olabilir.';
/// Mobilde ekranı olmayan bir kayıt satırı kalırsa gösterilir (şu an tüm
/// FİRMA KAYITLARI satırlarının mobil ekranı var).
const kCopyRegistryFooter = 'Bu kayıtlar web panelinden yönetilir.';
