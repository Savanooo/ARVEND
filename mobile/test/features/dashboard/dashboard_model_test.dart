import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/utils/event_labels.dart';
import 'package:arvend/core/utils/formatters.dart';
import 'package:arvend/core/widgets/status_badge.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/dashboard/domain/dashboard.dart';
import 'package:arvend/features/dashboard/domain/dashboard_registry.dart';
import 'package:arvend/features/dashboard/domain/mobile_routes.dart';

import 'fixtures.dart';

/// Ana sayfa sözleşmesi + saf kayıt defteri (spec §6.8 madde 1). Beklenen
/// değerler web `lib/dashboard.test.mts` / `lib/format.test.mts` ile AYNI
/// -- iki platform aynı fixture için aynı KPI'ları, bantları ve metinleri
/// göstermeli.
void main() {
  late Map<String, Dashboard> dash;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    dash = {for (final p in kDashboardPersonas) p: Dashboard.fromJson(fixtureJson(p))};
  });

  group('model', () {
    test('dört fixture da çözülür, üst alanlar dolu', () {
      for (final p in kDashboardPersonas) {
        final d = dash[p]!;
        expect(d.today, '2026-09-28', reason: p);
        expect(d.generatedAt, '2026-09-28T09:41:12+03:00', reason: p);
        expect(d.timezone, 'Europe/Istanbul', reason: p);
        expect(d.primaryCurrency, 'TRY', reason: p);
        expect(d.sectionErrors, isEmpty, reason: p);
      }
      final owner = dash['owner']!;
      expect(owner.sections.keys.length, 20);
      expect(owner.agenda.mineCount, 13);
      expect(owner.agenda.mineDangerCount, 7);
      expect(owner.agenda.watchingCount, 2);
      expect(owner.agenda.upcoming, hasLength(3));
      final fin = owner.sections.finance!.byCurrency;
      expect(fin.map((r) => r.currency), ['TRY', 'USD']);
      expect(fin.first.openReceivable, 5100000);
      expect(fin.first.collectionPct, 59.2);
      expect(fin.first.trend6m, hasLength(6));
      expect(fin.first.trend6m.first.month, '2026-04');
      expect(owner.sections.projects!.counts.total, 23);
      expect(owner.sections.products!.demirProfil, 3645);
      expect(owner.sections.users!.byRole.map((r) => r.code), contains('field'));
      expect(owner.onboarding, isNull);

      final empty = dash['empty_company']!;
      expect(empty.onboarding!.doneCount, 1);
      expect(empty.onboarding!.total, 6);
      expect(empty.onboarding!.steps.firstWhere((s) => s.key == 'catalog').detail, '628 ürün');
      expect(empty.onboarding!.steps.firstWhere((s) => s.key == 'customer').detail, isNull);
    });

    test('yanıtta olmayan bölüm anahtarı null (izin yok), izne bağlı alt blok null', () {
      final field = dash['field']!;
      expect(field.sections.keys, {'projects', 'tasks', 'operations', 'attendance', 'notifications', 'activity'});
      expect(field.sections.finance, isNull);
      expect(field.sections.offers, isNull);
      expect(field.sections.users, isNull);
      expect(field.sections.procurement, isNull);
      for (final row in field.sections.projects!.top) {
        expect(row.collectionPct, isNull);
        expect(row.currentValue, isNull);
        expect(row.taskProgressPct, isNotNull);
      }
      final finance = dash['finance']!;
      expect(finance.sections.tasks, isNull);
      expect(finance.sections.offers, isNull);
      for (final row in finance.sections.projects!.top) {
        expect(row.taskProgressPct, isNull);
        expect(row.overdueTaskCount, isNull);
      }
      expect(finance.sections.subcontracts!.claims!.certifiedUnpaid!.count, 1);
      expect(finance.sections.costControl!.overBudget!.worst!.overrunPct, 8.4);
    });

    test('section_errors çözülür ve bölüm kartı hâlâ görünür modüldür', () {
      final json = fixtureJson('owner');
      (json['sections'] as Map<String, dynamic>).remove('procurement');
      json['section_errors'] = {'procurement': 'section_failed'};
      final d = Dashboard.fromJson(json);
      expect(d.sectionErrors, {'procurement'});
      expect(d.sections.procurement, isNull);
      expect(d.sections.has('procurement'), isFalse);
      expect(visibleModules(d), contains(ModuleKey.procurement));
    });

    test('tanınmayan dikkat kodu / ref türü çökertmez, genel metinle gösterilir', () {
      final json = fixtureJson('owner');
      final agenda = json['agenda'] as Map<String, dynamic>;
      (agenda['groups'] as List<dynamic>).add({
        'code': 'future_code',
        'module': 'future_module',
        'lane': 'mine',
        'severity': 'action',
        'count': 2,
        'amounts': <dynamic>[],
        'oldest_days': null,
        'items': [
          {
            'ref': {'kind': 'future_kind', 'id': 'x', 'project_id': null, 'parent_id': null, 'action': 'open'},
            'label': 'Yeni tür',
            'project_name': null,
            'amount': null,
            'date': null,
            'days': null,
            'pct': null,
          },
        ],
      });
      final d = Dashboard.fromJson(json);
      final g = d.agenda.groups.last;
      expect(g.code, 'future_code');
      expect(attentionTitle(g), '2 kayıt dikkat gerektiriyor');
      expect(attentionRecordLine(g.items.single, g.code), 'Yeni tür');
      expect(mobileRouteFor(g.items.single.ref), isNull);
      expect(moduleRouteFor(g.module), isNull);
      // Çoklu grup Dikkat listesine gider; kaydı olmayan grup modül ekranına.
      expect(attentionGroupTarget(g)!.path, '/ana-sayfa/dikkat?kod=future_code');
      const noRecords = AttentionGroup(
        code: 'attendance_not_recorded',
        module: 'attendance',
        lane: 'mine',
        severity: 'action',
        count: 2,
        amounts: [],
        items: [],
      );
      expect(attentionGroupTarget(noRecords)!.path, '/diger/mesai');
      expect(attentionGroupTarget(noRecords)!.push, isTrue);
    });
  });

  group('mobileRouteFor', () {
    DashRef ref(String kind, {String id = 'r1', String? project = 'p1', String? parent, String action = 'open'}) =>
        DashRef(kind: kind, id: id, projectId: project, parentId: parent, action: action);

    test('22 ref türü + award/convert (spec §6.6)', () {
      final cases = <DashRef, String?>{
        ref('project', id: 'p1'): '/projeler/p1',
        ref('project_finance', id: 'p1'): '/projeler/p1?grup=finans&alt=finans',
        ref('project_cost', id: 'p1'): '/projeler/p1?grup=finans&alt=maliyet',
        ref('project_operations', id: 'p1'): '/projeler/p1?grup=operasyon&alt=gorevler',
        ref('offer', project: null): '/teklifler/r1',
        ref('offer', project: null, action: 'convert'): '/teklifler/r1',
        ref('task'): '/projeler/p1/gorevler/r1',
        ref('milestone'): '/projeler/p1?grup=operasyon&alt=gorevler',
        ref('purchase_request'): '/projeler/p1/satin-alma/talepler/r1',
        ref('rfq'): '/projeler/p1/satin-alma/rfqlar/r1',
        ref('rfq', action: 'award'): '/projeler/p1/satin-alma/rfqlar/r1/karsilastir',
        ref('purchase_order'): '/projeler/p1/satin-alma/siparisler/r1',
        ref('subcontract'): '/projeler/p1/taseronlar/r1',
        ref('progress_claim', parent: 's1'): '/projeler/p1/taseronlar/s1/hakedisler/r1',
        ref('subcontract_change_order', parent: 's1'): '/projeler/p1/taseronlar/s1/degisiklik-emirleri/r1',
        ref('change_order'): '/projeler/p1?grup=finans&alt=ek-isler',
        ref('budget_adjustment'): '/projeler/p1?grup=finans&alt=maliyet',
        ref('contract'): '/projeler/p1?grup=finans&alt=finans',
        ref('payment_plan_item'): '/projeler/p1?grup=finans&alt=finans',
        ref('invoice'): '/projeler/p1?grup=finans&alt=finans',
        ref('customer', project: null): '/diger/musteriler/r1',
        ref('product', project: null): '/diger/urunler/r1',
        ref('user', project: null): '/diger/kullanicilar/r1',
        ref('price_source', id: 'ulas', project: null): '/diger/urunler/kaynaklar',
      };
      cases.forEach((r, expected) {
        expect(mobileRouteFor(r), expected, reason: '${r.kind}/${r.action}');
      });
    });

    test('proje kimliği eksik kayıt türü dokunulamaz (null)', () {
      expect(mobileRouteFor(ref('task', project: null)), isNull);
      expect(mobileRouteFor(ref('purchase_order', project: null)), isNull);
    });

    test('FİRMA KAYITLARI satırlarının hepsi web kartıyla aynı mobil ekrana push eder', () {
      final expected = <ModuleKey, String>{
        ModuleKey.customers: '/diger/musteriler',
        ModuleKey.employees: '/diger/personel',
        ModuleKey.products: '/diger/urunler/zamlar?period=30',
        ModuleKey.users: '/diger/kullanicilar',
        ModuleKey.calculations: '/diger/metraj',
        ModuleKey.suppliers: '/diger/tedarikciler',
        ModuleKey.costCodes: '/diger/maliyet-kodlari',
      };
      for (final m in ModuleKey.values.where((m) => kModules[m]!.isRegistry)) {
        final route = kModules[m]!.route;
        expect(route?.path, expected[m], reason: m.wire);
        expect(route!.push, isTrue, reason: m.wire);
      }
      // Kaydı olmayan fiyat kaynağı grubu modül ekranına düşer.
      expect(moduleRouteFor('products')!.path, '/diger/urunler/zamlar?period=30');
    });

    test('yönetim CTA kapıları katıdır (fail-closed, Kullanıcı Ekle kaba rol admin ister)', () {
      expect(kCtaAddEmployee.allowedFor(ownerUser), isTrue);
      expect(kCtaAddUser.allowedFor(ownerUser), isTrue);
      expect(kCtaProducts.allowedFor(ownerUser), isTrue);
      // İzin kümesi boş/yüklenmemiş: `can`'ın aksine HİÇBİRİ açılmaz.
      final legacy = User(
        id: 'u',
        organizationId: 'o',
        username: 'u',
        fullName: 'U',
        role: UserRole.admin,
        isActive: true,
        mustChangePassword: false,
        onboardingCompleted: true,
        onboardingStep: 'completed',
        organizationName: 'O',
      );
      for (final cta in [kCtaAddEmployee, kCtaAddUser, kCtaProducts]) {
        expect(cta.allowedFor(legacy), isFalse, reason: cta.label);
        expect(cta.allowedFor(null), isFalse, reason: cta.label);
      }
      // Tüm izinler kişiye özel verilmiş olsa da kaba rol admin değilse
      // Kullanıcı Ekle kapalı (backend requireAdmin).
      final nonAdmin = User(
        id: 'u',
        organizationId: 'o',
        username: 'u',
        fullName: 'U',
        role: UserRole.kullanici,
        isActive: true,
        mustChangePassword: false,
        onboardingCompleted: true,
        onboardingStep: 'completed',
        organizationName: 'O',
        permissions: kAllPermissions.toSet(),
      );
      expect(kCtaAddUser.allowedFor(nonAdmin), isFalse);
      expect(kCtaAddEmployee.allowedFor(nonAdmin), isTrue);
      // Saha: ürün/personel izni yok.
      expect(kCtaProducts.allowedFor(fieldUser), isFalse);
      expect(kCtaAddEmployee.allowedFor(fieldUser), isFalse);
    });

    test('fixture kayıtlarının hepsi ya rotaya ya bilinçli null\'a çözülür', () {
      final claim = dash['owner']!.agenda.groups.firstWhere((g) => g.code == 'progress_claim_certify').items.single;
      expect(
        mobileRouteFor(claim.ref),
        '/projeler/0b000000-0000-4000-8000-000000000001/taseronlar/12000000-0000-4000-8000-000000000001'
        '/hakedisler/11000000-0000-4000-8000-000000000004',
      );
      final award = dash['finance']!.agenda.groups.firstWhere((g) => g.code == 'rfq_award').items.single;
      expect(mobileRouteFor(award.ref), endsWith('/karsilastir'));
    });
  });

  group('Formatters (spec D5 -- web format.test.mts ile aynı tablo)', () {
    test('moneyCompact', () {
      expect(Formatters.moneyCompact(850000), '850.000 TL');
      expect(Formatters.moneyCompact(999999.6), '1 Mn TL');
      expect(Formatters.moneyCompact(12500000), '12,5 Mn TL');
      expect(Formatters.moneyCompact(12000000), '12 Mn TL');
      expect(Formatters.moneyCompact(999960000), '1 Mr TL');
      expect(Formatters.moneyCompact(1250000000), '1,3 Mr TL');
      expect(Formatters.moneyCompact(-420000), '-420.000 TL');
      expect(Formatters.moneyCompact(45000, currency: 'USD'), '45.000 \$');
      expect(Formatters.moneyCompact(5100000), '5,1 Mn TL');
      expect(Formatters.moneyCompact(0), '0 TL');
      expect(Formatters.moneyCompact(-0.2), '0 TL');
    });

    test('signedMoneyCompact / signedMoney / percent', () {
      expect(Formatters.signedMoneyCompact(420000), '+420.000 TL');
      // Eksi U+2212 (kMinus): tablo rakamlı metinde "+" ile aynı genişlik.
      expect(Formatters.signedMoneyCompact(-70000), '${kMinus}70.000 TL');
      expect(Formatters.signedMoneyCompact(-0.4), '0 TL');
      expect(Formatters.signedMoneyCompact(0), '0 TL');
      expect(Formatters.signedMoneyCompact(2200000), '+2,2 Mn TL');
      expect(Formatters.signedMoney(950000), '+950.000,00 TL');
      expect(Formatters.signedMoney(-310000), '${kMinus}310.000,00 TL');
      expect(Formatters.percent(59.0), '%59');
      expect(Formatters.percent(62.5), '%62,5');
      expect(Formatters.percent(59.2), '%59,2');
      expect(Formatters.decimal(4120.5), '4.120,5');
      expect(Formatters.compactNumber(500000), '500.000');
      expect(Formatters.compactNumber(1000000), '1 Mn');
    });

    test('relative (şimdi = sunucunun generated_at değeri)', () {
      // Sayı-birim ve gün-saat arası bölünmez boşluk (kNbsp): dar satırda
      // "dün" ile "17:40" ayrı satırlara düşmez. Metin web ile aynıdır.
      const now = '2026-09-28T09:41:12+03:00';
      expect(Formatters.relative('2026-09-28T09:41:00+03:00', now), 'az önce');
      expect(Formatters.relative('2026-09-28T09:29:00+03:00', now), '12${kNbsp}dk önce');
      expect(Formatters.relative('2026-09-28T06:30:00+03:00', now), '3${kNbsp}sa önce');
      expect(Formatters.relative('2026-09-27T17:40:00+03:00', now), 'dün${kNbsp}17:40');
      expect(Formatters.relative('2026-09-25T14:05:00+03:00', now), '25.09${kNbsp}14:05');
      expect(Formatters.relative('2025-09-27T14:05:00+03:00', now), '27.09.2025');
      // Cihaz saat diliminden bağımsız: UTC damgası İstanbul saatine çevrilir.
      expect(Formatters.relative('2026-09-27T14:40:00Z', now), 'dün${kNbsp}17:40');
    });

    test('longDate / shortDayMonth / hm', () {
      expect(Formatters.longDate('2026-09-28'), '28 Eylül 2026, Pazartesi');
      expect(Formatters.shortDayMonth('2026-09-30'), '30 Eyl');
      expect(Formatters.shortDayMonth('2026-10-02'), '02 Eki');
      expect(Formatters.hm('2026-09-28T09:41:12+03:00'), '09:41');
      expect(Formatters.hm('2026-09-28T06:41:12Z'), '09:41');
    });
  });

  group('kayıt defteri -- personalara göre (web ile aynı beklentiler)', () {
    test('pickKpis', () {
      expect(pickKpis(dash['owner']!), [KpiKey.receivable, KpiKey.netCash, KpiKey.pipeline, KpiKey.cashBalance]);
      expect(pickKpis(dash['finance']!), [
        KpiKey.receivable,
        KpiKey.netCash,
        KpiKey.cashBalance,
        KpiKey.activeProjects,
      ]);
      expect(pickKpis(dash['field']!), [KpiKey.activeProjects, KpiKey.myTasks, KpiKey.teamOverdue, KpiKey.onSite]);
      // Yeni firma (rehber gizlenince): finans/teklif satırı boş, personel bağı yok.
      expect(pickKpis(dash['empty_company']!), [
        KpiKey.activeProjects,
        KpiKey.teamOverdue,
        KpiKey.onSite,
        KpiKey.unread,
      ]);
    });

    test('pickKpis -- personel bağı olmayan saha kullanıcısı (spec §8.3)', () {
      final json = fixtureJson('field');
      ((json['sections'] as Map)['tasks'] as Map)['mine'] = {
        'linked_employee': false,
        'open': 0,
        'overdue': 0,
        'due_today': 0,
        'items': <dynamic>[],
      };
      final d = Dashboard.fromJson(json);
      expect(pickKpis(d), [KpiKey.activeProjects, KpiKey.teamOverdue, KpiKey.onSite, KpiKey.unread]);
      expect(secondaryPanel(d), SecondaryPanel.none);
    });

    test('secondaryPanel', () {
      expect(secondaryPanel(dash['owner']!), SecondaryPanel.cash);
      expect(secondaryPanel(dash['finance']!), SecondaryPanel.cash);
      expect(secondaryPanel(dash['field']!), SecondaryPanel.myTasks);
    });

    test('secondaryPanel -- finans bölümü hesaplanamadıysa Nakit Akışı yerinde kalır', () {
      final json = fixtureJson('owner');
      (json['sections'] as Map<String, dynamic>).remove('finance');
      json['section_errors'] = {'finance': 'section_failed'};
      expect(secondaryPanel(Dashboard.fromJson(json)), SecondaryPanel.cash);
    });

    test('layoutBands -- sahip: 4 bant, 15 standart + 3 kompakt kart', () {
      final bands = layoutBands(dash['owner']!, onboardingActive: false);
      expect(bands.map((b) => b.title), ['NAKİT & SATIŞ', 'PROJE & SAHA', 'TEDARİK & MALİYET', 'FİRMA KAYITLARI']);
      expect(bands.expand((b) => b.standard), hasLength(15));
      expect(bands.expand((b) => b.compact), [ModuleKey.calculations, ModuleKey.suppliers, ModuleKey.costCodes]);
      expect(bands[1].standard, [
        ModuleKey.projects,
        ModuleKey.tasks,
        ModuleKey.operations,
        ModuleKey.contracts,
        ModuleKey.attendance,
      ]);
    });

    test('layoutBands -- saha: yoğun mod (BÖLÜMLER), 4 standart kart', () {
      final bands = layoutBands(dash['field']!, onboardingActive: false);
      expect(bands, hasLength(1));
      expect(bands.single.title, 'BÖLÜMLER');
      expect(bands.single.density, isTrue);
      expect(bands.single.standard, [ModuleKey.projects, ModuleKey.tasks, ModuleKey.operations, ModuleKey.attendance]);
    });

    test('layoutBands -- finans: 7 standart kart, bant başlıkları görünür', () {
      final bands = layoutBands(dash['finance']!, onboardingActive: false);
      expect(bands.map((b) => b.title), ['NAKİT & SATIŞ', 'PROJE & SAHA', 'TEDARİK & MALİYET', 'FİRMA KAYITLARI']);
      expect(bands.expand((b) => b.standard), hasLength(7));
      expect(bands.last.compact, [ModuleKey.suppliers, ModuleKey.costCodes]);
    });

    test('layoutBands -- yeni firma: kurulum düzeni, yer tutucu önce', () {
      final bands = layoutBands(dash['empty_company']!, onboardingActive: true);
      expect(bands, hasLength(1));
      expect(bands.single.placeholder, isTrue);
      expect(bands.single.standard, [
        ModuleKey.offers,
        ModuleKey.attendance,
        ModuleKey.customers,
        ModuleKey.employees,
        ModuleKey.products,
        ModuleKey.users,
      ]);
      expect(bands.single.compact, [ModuleKey.calculations, ModuleKey.suppliers, ModuleKey.costCodes]);
    });

    test('summarySentence (3 dal) ve scopeLine', () {
      expect(summarySentence(dash['owner']!.agenda), 'Bugün 13 iş senin sıranda; 7 tanesi acil.');
      expect(summarySentence(dash['empty_company']!.agenda), 'Bugün 1 iş senin sıranda.');
      expect(
        summarySentence(
          const DashboardAgenda(groups: [], upcoming: [], mineCount: 0, mineDangerCount: 0, watchingCount: 2),
        ),
        'Senin sıranda iş yok; 2 konu takipte.',
      );
      expect(
        summarySentence(
          const DashboardAgenda(groups: [], upcoming: [], mineCount: 0, mineDangerCount: 0, watchingCount: 0),
        ),
        'Bugün seni bekleyen bir iş yok.',
      );
      expect(scopeLine(dash['owner']!.viewer), isNull);
      expect(scopeLine(dash['field']!.viewer), 'Üyesi olduğun 2 projenin verileri gösteriliyor.');
      expect(
        scopeLine(
          const DashboardViewer(
            userId: 'u',
            organizationRoleCode: 'field',
            isAdmin: false,
            allProjects: false,
            accessibleProjectCount: 0,
          ),
        ),
        'Henüz bir projeye eklenmedin; yöneticin seni eklediğinde proje verileri burada görünür.',
      );
    });

    test('attentionChip tonları ve modül grupları', () {
      final owner = dash['owner']!;
      expect(attentionChip(moduleGroups(owner, ModuleKey.finance)), ('4 uyarı', StatusTone.danger));
      expect(attentionChip(moduleGroups(owner, ModuleKey.procurement)), ('3 bekliyor', StatusTone.warning));
      expect(attentionChip(moduleGroups(owner, ModuleKey.changeOrders)), ('2 takipte', StatusTone.info));
      expect(attentionChip(moduleGroups(owner, ModuleKey.customers)), isNull);
      // Birden çok grup: uyarı sayısı yalnızca danger gruplarının toplamıdır.
      final finance = dash['finance']!;
      expect(attentionChip(moduleGroups(finance, ModuleKey.finance)), ('2 uyarı', StatusTone.danger));
      expect(attentionChip(moduleGroups(finance, ModuleKey.costControl)), ('1 uyarı', StatusTone.danger));
    });

    test('dikkat başlıkları, kayıt satırları ve alt bilgi', () {
      final owner = dash['owner']!;
      AttentionGroup g(Dashboard d, String code) => d.agenda.groups.firstWhere((x) => x.code == code);
      expect(attentionTitle(g(owner, 'plan_item_overdue')), '4 ödeme planı kaleminin vadesi geçti');
      // Web ile aynı metin; yalnızca sayı ile birim arası bölünmez boşluk.
      expect(attentionMeta(g(owner, 'plan_item_overdue')), '850.000,00 TL · en eski 21${kNbsp}gün');
      expect(
        attentionRecordLine(g(owner, 'plan_item_overdue').items.first, 'plan_item_overdue'),
        '2. Hakediş · Kadıköy Konut Projesi · 21${kNbsp}gün gecikti',
      );
      expect(attentionTitle(g(owner, 'change_order_awaiting_customer')), '2 ek iş müşteri onayında');
      expect(
        attentionMeta(g(owner, 'progress_claim_certify')),
        'HK-004 · Kadıköy Konut Projesi · 3${kNbsp}gündür bekliyor · 90.000,00 TL',
      );
      expect(
        attentionRecordLine(g(owner, 'project_past_end').items.first, 'project_past_end'),
        'PRJ-2026-0003 Beykoz Müstakil Konut · 12${kNbsp}gün geçti',
      );
      expect(attentionTitle(g(owner, 'users_without_project')), '2 kullanıcı hiçbir projeyi göremiyor');
      final finance = dash['finance']!;
      expect(
        attentionRecordLine(g(finance, 'over_budget').items.single, 'over_budget'),
        'PRJ-2026-0002 Ataşehir Villa İnşaatı · %8,4${kNbsp}aşım',
      );
      expect(
        attentionRecordLine(g(finance, 'budget_adjustment_approval').items.single, 'budget_adjustment_approval'),
        'Ek kalıp malzemesi · Ataşehir Villa İnşaatı · 2${kNbsp}gündür bekliyor',
      );
      expect(relativeDays(0), 'bugün');
      expect(relativeDays(1), 'dün');
      expect(relativeDays(9), '9${kNbsp}gün önce');
      expect(attentionTitle(g(finance, 'rfq_award')), "1 RFQ'da teklifler toplandı, karar bekliyor");
      final field = dash['field']!;
      expect(attentionTitle(g(field, 'my_task_overdue')), '2 görevin gecikti');
      expect(attentionMeta(g(field, 'my_task_overdue')), 'en eski 5${kNbsp}gün');
      final empty = dash['empty_company']!;
      expect(attentionTitle(g(empty, 'price_sync_never')), 'Demir Profil fiyat kaynağı hiç senkronlanmadı');
    });

    test('yaklaşan etiketleri ve Bugün/Yarın', () {
      expect(upcomingLabel('plan_item_due'), 'Ödeme planı');
      expect(upcomingLabel('offer_expiry'), 'Teklif süresi doluyor');
      expect(upcomingLabel('my_task_due'), 'Görev');
      expect(upcomingDateLabel('2026-09-28', '2026-09-28'), 'Bugün');
      expect(upcomingDateLabel('2026-09-29', '2026-09-28'), 'Yarın');
      expect(upcomingDateLabel('2026-10-01', '2026-09-30'), 'Yarın');
      expect(upcomingDateLabel('2026-09-30', '2026-09-28'), '30 Eyl');
      expect(attentionTotal(dash['owner']!.agenda), 18);
      expect(attentionTotal(dash['field']!.agenda), 8);
    });

    test('quickActionsFor -- personalara göre (spec §8)', () {
      expect(quickActionsFor(ownerUser).map((a) => a.label), [
        'Teklif Oluştur',
        'Tahsilat Gir',
        'Masraf Gir',
        'Mesai Gir',
        'Satın Alma Talebi',
        'Görev Ekle',
        'Not Ekle',
        'Müşteri Ekle',
        'Metraj Hesapla',
      ]);
      expect(quickActionsFor(fieldUser).map((a) => a.label), ['Not Ekle']);
      expect(quickActionsFor(financeUser).map((a) => a.label), ['Tahsilat Gir', 'Masraf Gir', 'Satın Alma Talebi']);
      // Mesai Gir iki izin ister (attendance.manage VE employees.read).
      final onlyAttendance = User(
        id: 'u',
        username: 'u',
        fullName: 'U',
        role: UserRole.kullanici,
        isActive: true,
        mustChangePassword: false,
        onboardingCompleted: true,
        onboardingStep: 'completed',
        permissions: const {'attendance.manage'},
      );
      expect(quickActionsFor(onlyAttendance), isEmpty);
      // İzin kümesi boşsa (eski oturum) fail-open.
      expect(quickActionsFor(null), hasLength(QuickActionKey.values.length));
    });

    test('predictSections, sunucunun bölüm kümesiyle aynı', () {
      for (final p in kDashboardPersonas) {
        expect(predictSections(userFor(p)), dash[p]!.sections.keys, reason: p);
      }
      expect(predictSections(null), isNull);
    });

    test('fixture\'lardaki her olay tipi etiketlidir ("Kayıt güncellendi"ye düşmez)', () {
      for (final p in kDashboardPersonas) {
        for (final item in dash[p]!.sections.activity!.items) {
          expect(eventLabel(item.source, item.eventType), isNot(kUnknownEventLabel), reason: item.eventType);
        }
      }
      expect(eventLabel('project', 'bilinmeyen_olay'), 'Kayıt güncellendi');
    });

    test('backend\'in her ProjectEvent* sabiti etiketli (domain kaynağı taranır)', () {
      final pattern = RegExp(r'ProjectEvent\w+\s*=\s*"([^"]+)"');
      final types = <String>{
        for (final f in Directory('../backend/internal/domain').listSync().whereType<File>())
          if (f.path.endsWith('.go') && !f.path.endsWith('_test.go'))
            for (final m in pattern.allMatches(f.readAsStringSync())) m.group(1)!,
      };
      expect(types.length, greaterThan(50));
      final missing = types.where((t) => !kProjectEventLabels.containsKey(t)).toList()..sort();
      expect(missing, isEmpty, reason: 'etiketsiz olay tipleri: $missing');
      expect(eventLabel('offer', 'customer_viewed'), 'Müşteri teklifi görüntüledi');
    });
  });
}
