import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/widgets/app_data_row.dart';
import 'package:arvend/core/widgets/app_list_card.dart';
import 'package:arvend/core/widgets/status_badge.dart';
import 'package:arvend/features/attendance/presentation/attendance_screen.dart';
import 'package:arvend/features/calculations/domain/calc.dart';
import 'package:arvend/features/calculations/presentation/metraj_screen.dart';
import 'package:arvend/features/projects/presentation/bid_comparison_screen.dart';
import 'package:arvend/features/projects/presentation/progress_claim_detail_screen.dart';
import 'package:arvend/features/projects/presentation/purchase_order_detail_screen.dart';
import 'package:arvend/features/projects/presentation/subcontract_detail_screen.dart';

import 'test_utils/fake_api_client.dart';

/// Faz 3 — ağır operasyonel modüllerin (satın alma/taşeron/metraj/mesai)
/// yeniden tasarımı. Bu testler iş mantığını DEĞİL (o zaten repository/
/// provider testleriyle kapsanıyor), Faz 3'ün özellikle talep ettiği
/// GÖRSEL/YAPISAL doğrulukları kapsar: durum semantiği düzeltmeleri (PO
/// approved, RFQ awarded), Teklif Karşılaştırma'nın gerçek yan yana
/// karşılaştırma sağlaması, ve taşeron/hakediş ekranlarında "sertifika ≠
/// ödeme" ayrımının GÖRSEL OLARAK asla birleştirilmediği.
Map<String, dynamic> _meJson({List<String> permissions = const []}) => {
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'test',
      'full_name': 'Ayşe Yılmaz',
      'organization_name': 'ARVEND Yapı A.Ş.',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': permissions,
    };

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, Widget child, {Size size = const Size(400, 1600)}) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('Durum semantiği düzeltmeleri (madde 19)', () {
    test('PurchaseOrder "approved" success tonu kullanır, gold DEĞİL', () {
      final entry = StatusRegistry.purchaseOrder['approved']!;
      expect(entry.$2, StatusTone.success);
    });

    test('RFQ "awarded" paylaşılan StatusRegistry.awardedQuotation rozetini kullanır', () {
      expect(StatusRegistry.awardedQuotation.tone, StatusTone.success);
      expect(StatusRegistry.awardedQuotation.label, 'Ödüllendirildi');
    });
  });

  group('BidComparisonScreen — gerçek yan yana karşılaştırma', () {
    testWidgets('kriter etiketleri + tedarikçi sütunları render edilir, ödüllendirilen işaretlenir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/projects/p1/rfqs/rfq1/comparison': [
          (
            status: 200,
            body: {
              'rows': [
                {
                  'item': {'id': 'i1', 'description': 'Çimento', 'quantity': 10, 'unit': 'torba', 'sort_order': 1},
                  'cells': {
                    's1': {'supplier_id': 's1', 'quantity': 10, 'unit_price': 100, 'line_total': 1000},
                    's2': {'supplier_id': 's2', 'quantity': 10, 'unit_price': 90, 'line_total': 900},
                  },
                },
              ],
              'quotations': [
                {
                  'id': 'q1', 'rfq_id': 'rfq1', 'supplier_id': 's1', 'supplier_name': 'Tedarikçi A',
                  'quotation_number': 'TF-1', 'quotation_date': '2026-09-01', 'currency': 'TRY',
                  'subtotal': 1000, 'discount': 0, 'tax_rate': 20, 'tax': 200, 'total': 1200,
                  'delivery_days': 7, 'payment_terms': 'Peşin',
                },
                {
                  'id': 'q2', 'rfq_id': 'rfq1', 'supplier_id': 's2', 'supplier_name': 'Tedarikçi B',
                  'quotation_number': 'TF-2', 'quotation_date': '2026-09-02', 'currency': 'TRY',
                  'subtotal': 900, 'discount': 0, 'tax_rate': 20, 'tax': 180, 'total': 1080,
                  'delivery_days': 5, 'payment_terms': 'Vadeli',
                },
              ],
            },
          ),
        ],
        '/projects/p1/rfqs/rfq1': [
          (
            status: 200,
            body: {
              'rfq': {
                'id': 'rfq1', 'rfq_no': 'RFQ-1', 'title': 'Çimento RFQ', 'issue_date': '2026-08-01',
                'status': 'closed', 'awarded_quotation_id': 'q2', 'awarded_at': '2026-09-05T00:00:00Z',
              },
              'items': <dynamic>[],
              'suppliers': <dynamic>[],
            },
          ),
        ],
      });
      await _pump(tester, adapter, const BidComparisonScreen(projectId: 'p1', rfqId: 'rfq1'));

      expect(find.text('Toplam Tutar'), findsOneWidget);
      expect(find.text('Teslimat Süresi'), findsOneWidget);
      expect(find.text('Tedarikçi A'), findsOneWidget);
      expect(find.text('Tedarikçi B'), findsOneWidget);
      // Yalnızca ödüllendirilen (q2 / Tedarikçi B) rozeti taşır -- en ucuz
      // olmak OTOMATİK "ödüllendirildi" anlamına gelmez, backend'in
      // awarded_quotation_id'si tek doğruluk kaynağıdır.
      expect(find.text('Ödüllendirildi'), findsOneWidget);
    });
  });

  group('PurchaseOrderDetailScreen — approved success tonuyla gösterilir', () {
    testWidgets('onaylanmış sipariş success renkli StatusBadge kullanır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/projects/p1/purchase-orders/po1': [
          (
            status: 200,
            body: {
              'purchase_order': {
                'id': 'po1', 'po_no': 'PO-1', 'supplier_id': 's1', 'supplier_name': 'Tedarikçi A',
                'currency': 'TRY', 'status': 'approved', 'issue_date': '2026-09-01', 'payment_terms': '',
                'delivery_address': '', 'notes': '', 'subtotal': 1000, 'tax_rate': 20, 'tax': 200, 'total': 1200,
              },
              'items': <dynamic>[],
              'commitments': <dynamic>[],
            },
          ),
        ],
      });
      await _pump(tester, adapter, const PurchaseOrderDetailScreen(projectId: 'p1', poId: 'po1'));

      final badge = tester.widget<StatusBadge>(find.byType(StatusBadge).first);
      expect(badge.label, 'Onaylandı');
      expect(badge.tone, StatusTone.success);
    });
  });

  group('SubcontractDetailScreen — mali ayrım (madde 7/8)', () {
    testWidgets('Sertifikalı Toplam ve Ödenen Toplam ayrı satırlar olarak farklı değerlerle gösterilir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.subcontracts.manage']))],
        '/projects/p1/subcontracts/sc1': [
          (
            status: 200,
            body: {
              'subcontract': {
                'id': 'sc1', 'subcontract_no': 'TAS-1', 'supplier_id': 's1', 'supplier_name': 'Taşeron A',
                'title': 'Elektrik Tesisatı', 'scope_summary': '', 'original_amount': 100000, 'currency': 'TRY',
                'status': 'active', 'created_at': '2026-01-01T00:00:00Z',
              },
              'items': <dynamic>[],
              'current_value': {
                'original_amount': 100000, 'approved_additions': 5000, 'approved_deductions': 0,
                'pending_additions': 0, 'pending_deductions': 0, 'current_value': 105000,
                'certified_to_date': 80000, 'remaining_commitment': 25000,
                'paid_to_date': 50000, 'remaining_payable': 30000,
              },
            },
          ),
        ],
        '/projects/p1/subcontracts/sc1/payments': [(status: 200, body: {'payments': <dynamic>[]})],
        '/projects/p1/subcontracts/sc1/progress-claims': [(status: 200, body: {'progress_claims': <dynamic>[]})],
        '/projects/p1/subcontracts/sc1/change-orders': [(status: 200, body: {'change_orders': <dynamic>[]})],
        '/organization/cost-codes': [(status: 200, body: {'cost_codes': <dynamic>[]})],
      });
      await _pump(tester, adapter, const SubcontractDetailScreen(projectId: 'p1', subcontractId: 'sc1'), size: const Size(400, 2400));

      final rows = tester.widgetList<AppDataRow>(find.byType(AppDataRow)).toList();
      final certified = rows.firstWhere((r) => r.label == 'Sertifikalı Toplam');
      final paid = rows.firstWhere((r) => r.label == 'Ödenen Toplam');
      expect(certified.value, contains('80.000'));
      expect(paid.value, contains('50.000'));
      expect(certified.value, isNot(equals(paid.value)));
    });
  });

  group('ProgressClaimDetailScreen — sertifika ≠ ödeme (madde 10)', () {
    testWidgets('Net Hakediş ve Ödeme Durumu ayrı bölümlerde, biri diğerini "ödendi" diye göstermez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.subcontract_claims.manage', 'projects.subcontract_claims.certify']))],
        '/projects/p1/subcontract-progress-claims/claim1': [
          (
            status: 200,
            body: {
              'progress_claim': {
                'id': 'claim1', 'subcontract_id': 'sc1', 'claim_number': 'HAK-1', 'period_end': '2026-09-30',
                'status': 'certified', 'gross_work_amount': 20000, 'retention_percent_snapshot': 5,
                'retention_amount': 1000, 'advance_recovery_amount': 0, 'other_deductions': 0,
                'previous_certified_amount': 60000, 'current_certified_amount': 79000, 'net_payable': 19000,
                'certified_at': '2026-09-28T00:00:00Z',
              },
              'items': <dynamic>[],
            },
          ),
        ],
        '/projects/p1/subcontracts/sc1': [
          (
            status: 200,
            body: {
              'subcontract': {
                'id': 'sc1', 'subcontract_no': 'TAS-1', 'supplier_id': 's1', 'title': '', 'scope_summary': '',
                'original_amount': 100000, 'currency': 'TRY', 'status': 'active', 'created_at': '2026-01-01T00:00:00Z',
              },
              'items': <dynamic>[],
              'current_value': {
                'original_amount': 100000, 'approved_additions': 0, 'approved_deductions': 0,
                'pending_additions': 0, 'pending_deductions': 0, 'current_value': 100000,
                'certified_to_date': 79000, 'remaining_commitment': 21000,
                'paid_to_date': 60000, 'remaining_payable': 19000,
              },
            },
          ),
        ],
        '/projects/p1/subcontracts/sc1/payments': [
          (
            status: 200,
            body: {
              'payments': [
                {
                  'id': 'pay1', 'progress_claim_id': 'claim1', 'amount': 15000, 'currency': 'TRY',
                  'paid_date': '2026-09-15', 'payment_method': 'Havale', 'reference_no': '', 'description': '',
                  'created_at': '2026-09-15T00:00:00Z',
                },
              ],
            },
          ),
        ],
      });
      await _pump(
        tester,
        adapter,
        const ProgressClaimDetailScreen(projectId: 'p1', subcontractId: 'sc1', claimId: 'claim1'),
        size: const Size(400, 2400),
      );

      expect(find.text('Hakediş'), findsOneWidget);
      expect(find.text('Ödeme Durumu'), findsOneWidget);
      final rows = tester.widgetList<AppDataRow>(find.byType(AppDataRow)).toList();
      final net = rows.firstWhere((r) => r.label == 'Net Hakediş');
      final paidAgainst = rows.firstWhere((r) => r.label == 'Bu Hakedişe Karşı Ödenen');
      final remaining = rows.firstWhere((r) => r.label == 'Ödenmemiş Kalan');
      expect(net.value, contains('19.000'));
      expect(paidAgainst.value, contains('15.000'));
      expect(remaining.value, contains('4.000'));
      expect(find.textContaining('Sertifika edilmiş olmak ödendiği anlamına gelmez'), findsOneWidget);
    });
  });

  group('MetrajScreen — kategori kartı ad + açıklama', () {
    testWidgets('kategori seçildiğinde ad ve açıklama birlikte gösterilir, ilgisiz alanlar gizli kalır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/calculations/categories': [
          (
            status: 200,
            body: {
              'groups': [
                {
                  'id': 'g1', 'slug': 'duvar', 'name': 'Duvar',
                  'categories': [
                    {
                      'id': 'c1', 'group_id': 'g1', 'slug': 'sivali-duvar', 'name': 'Sıvalı Duvar',
                      'description': 'Sıva + boya dahil duvar hesaplaması',
                    },
                  ],
                },
              ],
            },
          ),
        ],
      });
      await _pump(tester, adapter, const MetrajScreen(), size: const Size(400, 1800));

      // Kategori kartları yalnızca bir Grup seçildikten sonra görünür.
      await tester.tap(find.byType(DropdownButtonFormField<CalcGroupWithCategories>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duvar').last);
      await tester.pumpAndSettle();

      expect(find.text('Sıvalı Duvar'), findsOneWidget);
      expect(find.text('Sıva + boya dahil duvar hesaplaması'), findsOneWidget);
      await tester.tap(find.text('Sıvalı Duvar'));
      await tester.pumpAndSettle();

      // Çatı kategorisi değil -- eğim (pitch) alanı gösterilmemeli.
      expect(find.text('Çatı Eğimi (°)'), findsNothing);
    });
  });

  group('AttendanceScreen — izin/aksiyon görünürlüğü ve Eksik Kayıtlar ayrımı', () {
    testWidgets('attendance.manage izni olmayan kullanıcı için satıra dokunma ve ekleme FAB\'ı yok', (tester) async {
      final today = DateTime.now();
      final todayIso = '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['attendance.read']))],
        '/attendance': [
          (
            status: 200,
            body: {
              'attendance': [
                {
                  'id': 'a1', 'employee_id': 'e1', 'employee_name': 'Mehmet Usta', 'date': todayIso,
                  'check_in': '08:00', 'check_out': '17:00', 'work_hours': 9, 'status': 'geldi', 'note': '',
                },
              ],
            },
          ),
        ],
        '/employees': [
          (
            status: 200,
            body: {
              'employees': [
                {'id': 'e1', 'full_name': 'Mehmet Usta', 'position': 'Elektrikçi', 'is_active': true},
                {'id': 'e2', 'full_name': 'Ali Kaya', 'position': 'Duvarcı', 'is_active': true},
              ],
            },
          ),
        ],
      });
      await _pump(tester, adapter, const AttendanceScreen(), size: const Size(400, 1800));

      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Bugün'), findsOneWidget);
      // Mehmet Usta'nın bugünkü kaydı var, Ali Kaya'nınki yok -> yalnızca
      // Ali Kaya "Eksik Kayıtlar" altında, Mehmet Usta'nın "Bugün" satırından
      // AÇIKÇA ayrı bir bölümde.
      expect(find.text('Eksik Kayıtlar'), findsOneWidget);
      expect(find.text('Ali Kaya'), findsOneWidget);
      expect(find.text('Kayıt Yok'), findsOneWidget);

      // Aylık/Geçmiş listesindeki hiçbir satır düzenlemeye açılmamalı --
      // "Bugün" satırları zaten hiçbir zaman tıklanabilir değildir (yalnızca
      // Aylık/Geçmiş `canManage`'e göre onTap alır).
      final monthlyCards = tester.widgetList<AppListCard>(find.byType(AppListCard));
      expect(monthlyCards, isNotEmpty);
      expect(monthlyCards.every((c) => c.onTap == null), isTrue);
    });
  });
}
