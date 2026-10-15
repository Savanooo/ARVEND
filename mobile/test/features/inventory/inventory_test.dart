import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/inventory/inventory_routes.dart';
import 'package:arvend/features/inventory/presentation/barcode_scanner.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import '../projects/form_test_support.dart' show requestBodyFor;

/// Stok Takibi (backend migration 0072): liste ve uyarılar, yeni fiş
/// (giriş, çıkış, sayım), fiş iptali, depolar; izinlere göre düğmeler.

final _admin = cc.buildUser(
  id: 'adm',
  roleCode: 'admin',
  permissions: const {'inventory.read', 'inventory.manage', 'inventory.adjust', 'projects.read'},
);
final _manager = cc.buildUser(
  id: 'pm',
  roleCode: 'project_manager',
  permissions: const {'inventory.read', 'inventory.manage'},
);
final _viewer = cc.buildUser(id: 'field', roleCode: 'field', permissions: const {'inventory.read'});

Map<String, dynamic> _item(String id, String name, {double qty = 0, bool track = false, String? nearest,
        double expired = 0, double expiring = 0, bool belowMin = false}) =>
    {
      'id': id,
      'code': 'STK-000${id.substring(1)}',
      'name': name,
      'barcode': '',
      'unit': track ? 'torba' : 'boy',
      'category': '',
      'product_id': null,
      'min_stock': belowMin ? 10 : null,
      'track_expiry': track,
      'shelf_life_months': track ? 3 : null,
      'expiry_policy': track ? 'block' : 'warn',
      'expiry_alert_days': 30,
      'notes': '',
      'is_active': true,
      'quantity': qty,
      'nearest_expiry': nearest,
      'expired_quantity': expired,
      'expiring_quantity': expiring,
      'below_min': belowMin,
    };

Map<String, dynamic> _items({bool values = false}) => {
      'items': [
        {..._item('i1', 'Kutu Profil 40x40', qty: 18, belowMin: true), if (values) 'avg_unit_cost': 150, if (values) 'stock_value': 2700},
        _item('i2', 'Çimento CEM I', qty: 25, track: true, nearest: '2026-10-01', expired: 5),
      ],
      'can_see_values': values,
    };

Map<String, dynamic> _summary({bool values = false}) => {
      'item_count': 2,
      'expired_lot_count': 1,
      'expiring_lot_count': 0,
      'below_min_count': 1,
      'can_see_values': values,
      if (values) 'stock_value': 2700,
    };

const _warehouses = {
  'warehouses': [
    {'id': 'w1', 'name': 'Merkez Depo', 'address': '', 'notes': '', 'is_active': true, 'item_count': 2},
    {'id': 'w2', 'name': 'Yan Depo', 'address': '', 'notes': '', 'is_active': true, 'item_count': 0},
  ],
};

Map<String, dynamic> _doc(String id, String type, {String status = 'posted', List<Map<String, dynamic>>? lines}) => {
      'id': id,
      'doc_no': 'STK-2026-0000${id.substring(1)}',
      'doc_type': type,
      'doc_date': '2026-10-15',
      'status': status,
      'counterparty': 'Demir Profil',
      'reference_no': 'IRS-7',
      'reason': '',
      'warehouse_name': 'Merkez Depo',
      'target_warehouse_name': '',
      'project_name': '',
      'created_by_name': 'Yönetici',
      'created_at': '2026-10-15T08:00:00Z',
      'item_count': 1,
      'first_item_name': 'Kutu Profil 40x40',
      'is_reversal': type == 'reversal',
      'warehouse_id': 'w1',
      'target_warehouse_id': null,
      'project_id': null,
      'project_no': '',
      'supplier_id': null,
      'supplier_name': '',
      'note': '',
      'has_attachment': false,
      'attachment_name': '',
      'attachment_mime': '',
      'reversal_of_id': null,
      'reversal_of_no': '',
      'reversed_by_doc_id': null,
      'reversed_by_doc_no': '',
      'reversed_at': null,
      'reversed_by_name': '',
      'reverse_reason': '',
      'lines': lines ??
          [
            {
              'line_no': 1,
              'item_id': 'i1',
              'item_code': 'STK-0001',
              'item_name': 'Kutu Profil 40x40',
              'unit': 'boy',
              'warehouse_id': 'w1',
              'warehouse_name': 'Merkez Depo',
              'lot_id': null,
              'lot_no': '',
              'expiry_date': null,
              'quantity': type == 'receipt' ? 10 : -2,
            },
          ],
      'warnings': [],
    };

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required User user,
  required Map<String, List<ScriptedResponse>> script,
  required String initial,
  String? scanned,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/diger', builder: (c, s) => const Scaffold(body: Text('diğer')), routes: inventoryRoutes),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
        barcodeScannerProvider.overrideWithValue((_) async => scanned),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('liste: miktar, SKT ve azalan işaretleri, özet; değer yalnızca yetkiliye', (tester) async {
    await _pump(tester, user: _admin, initial: '/diger/stok', script: {
      '/inventory/items': [(status: 200, body: _items(values: true))],
      '/inventory/summary': [(status: 200, body: _summary(values: true))],
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
    });
    expect(find.text('Kutu Profil 40x40'), findsOneWidget);
    expect(find.text('18 boy'), findsOneWidget);
    expect(find.textContaining('SKT geçti: 5 torba'), findsOneWidget);
    expect(find.text('Azalan'), findsWidgets);
    expect(find.byKey(const ValueKey('stok-ozet-skt-gecti')), findsOneWidget);
    expect(find.byKey(const ValueKey('stok-ozet-deger')), findsOneWidget);
    expect(find.byKey(const ValueKey('stok-islem')), findsOneWidget);
    // SKT filtresi yalnızca çimentoyu bırakır.
    await tester.tap(find.text('SKT'));
    await tester.pumpAndSettle();
    expect(find.text('Kutu Profil 40x40'), findsNothing);
    expect(find.text('Çimento CEM I'), findsOneWidget);
  });

  testWidgets('salt okuyan işlem yapamaz, değer görmez', (tester) async {
    await _pump(tester, user: _viewer, initial: '/diger/stok', script: {
      '/inventory/items': [(status: 200, body: _items())],
      '/inventory/summary': [(status: 200, body: _summary())],
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
    });
    expect(find.byKey(const ValueKey('stok-islem')), findsNothing);
    expect(find.byKey(const ValueKey('stok-ozet-deger')), findsNothing);
  });

  testWidgets('işlem menüsü: proje yöneticisinde fire ve sayım yok', (tester) async {
    await _pump(tester, user: _manager, initial: '/diger/stok', script: {
      '/inventory/items': [(status: 200, body: _items())],
      '/inventory/summary': [(status: 200, body: _summary())],
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
    });
    await tester.tap(find.byKey(const ValueKey('stok-islem')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stok-islem-receipt')), findsOneWidget);
    expect(find.byKey(const ValueKey('stok-islem-issue')), findsOneWidget);
    expect(find.byKey(const ValueKey('stok-islem-waste')), findsNothing);
    expect(find.byKey(const ValueKey('stok-islem-count')), findsNothing);
  });

  testWidgets('giriş: malzeme seçilir, miktar ve fiyat girilir, fiş açılır', (tester) async {
    final adapter = await _pump(tester, user: _admin, initial: '/diger/stok/fis/receipt?depo=w1', script: {
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
      '/inventory/items': [(status: 200, body: _items())],
      '/inventory/receipts': [(status: 201, body: _doc('d1', 'receipt'))],
      '/inventory/documents/d1': [(status: 200, body: _doc('d1', 'receipt'))],
    });
    await tester.enterText(find.byKey(const ValueKey('stok-fis-kimden')), 'Demir Profil');
    await tester.enterText(find.byKey(const ValueKey('stok-fis-irsaliye')), 'IRS-7');
    await tester.tap(find.byKey(const ValueKey('stok-satir-ekle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stok-secenek-i1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('stok-satir-miktar-i1')), '10');
    await tester.enterText(find.byKey(const ValueKey('stok-satir-fiyat-i1')), '125,5');
    await tester.tap(find.byKey(const ValueKey('stok-fis-kaydet')));
    await tester.pumpAndSettle();

    final body = requestBodyFor(adapter, '/inventory/receipts');
    expect(body['warehouse_id'], 'w1');
    expect(body['counterparty'], 'Demir Profil');
    expect(body['reference_no'], 'IRS-7');
    expect((body['idempotency_key'] as String).startsWith('stk-'), isTrue);
    expect(body['lines'], [
      {'item_id': 'i1', 'quantity': 10.0, 'unit_cost': 125.5},
    ]);
    expect(find.text('STK-2026-00001'), findsWidgets);
  });

  testWidgets('giriş: SKT takipli malzemede tarih girilmeden kaydedilmez', (tester) async {
    final adapter = await _pump(tester, user: _admin, initial: '/diger/stok/fis/receipt?depo=w1', script: {
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
      '/inventory/items': [(status: 200, body: _items())],
    });
    await tester.tap(find.byKey(const ValueKey('stok-satir-ekle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stok-secenek-i2')));
    await tester.pumpAndSettle();
    expect(find.text('SKT gir *'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('stok-satir-miktar-i2')), '5');
    await tester.tap(find.byKey(const ValueKey('stok-fis-kaydet')));
    await tester.pumpAndSettle();
    expect(find.textContaining('son kullanma tarihini girin'), findsOneWidget);
    expect(adapter.calls, isNot(contains('/inventory/receipts')));
  });

  testWidgets('çıkış: sunucunun yetersiz stok mesajı gösterilir', (tester) async {
    await _pump(tester, user: _manager, initial: '/diger/stok/fis/issue?depo=w1&malzeme=i1', script: {
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
      '/inventory/items/i1': [
        (status: 200, body: {'item': _item('i1', 'Kutu Profil 40x40', qty: 18), 'balances': [], 'documents': []}),
      ],
      '/inventory/issues': [
        (status: 409, body: {'error': 'satır 1 (Kutu Profil 40x40): Merkez Depo deposunda 18 boy var, 50 boy istendi'}),
      ],
    });
    expect(find.text('Kutu Profil 40x40'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('stok-fis-kime')), 'Ali Usta');
    await tester.enterText(find.byKey(const ValueKey('stok-satir-miktar-i1')), '50');
    await tester.tap(find.byKey(const ValueKey('stok-fis-kaydet')));
    await tester.pumpAndSettle();
    expect(find.textContaining('18 boy var, 50 boy istendi'), findsOneWidget);
  });

  testWidgets('sayım: depodaki satırlar gelir, yalnızca sayılan gönderilir', (tester) async {
    final adapter = await _pump(tester, user: _admin, initial: '/diger/stok/fis/count?depo=w1', script: {
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
      '/inventory/warehouses/w1/balances': [
        (
          status: 200,
          body: {
            'balances': [
              {'item_id': 'i1', 'item_code': 'STK-0001', 'item_name': 'Kutu Profil 40x40', 'unit': 'boy', 'lot_id': null, 'lot_no': '', 'expiry_date': null, 'quantity': 18},
              {'item_id': 'i2', 'item_code': 'STK-0002', 'item_name': 'Çimento CEM I', 'unit': 'torba', 'lot_id': 'l1', 'lot_no': 'B1', 'expiry_date': '2026-12-01', 'quantity': 20},
            ],
          },
        ),
      ],
      '/inventory/items': [(status: 200, body: _items())],
      '/inventory/counts': [(status: 201, body: _doc('d3', 'count'))],
      '/inventory/documents/d3': [(status: 200, body: _doc('d3', 'count'))],
    });
    expect(find.textContaining('Sistemde 18 boy'), findsOneWidget);
    expect(find.textContaining('Parti B1'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('stok-satir-miktar-i1')), '16');
    await tester.tap(find.byKey(const ValueKey('stok-fis-kaydet')));
    await tester.pumpAndSettle();
    final body = requestBodyFor(adapter, '/inventory/counts');
    expect(body['lines'], [
      {'item_id': 'i1', 'counted_quantity': 16.0},
    ]);
  });

  testWidgets('fiş iptali gerekçeyle yapılır; yetkisi olmayana düğme yok', (tester) async {
    final adapter = await _pump(tester, user: _admin, initial: '/diger/stok/hareketler/d1', script: {
      '/inventory/documents/d1': [
        (status: 200, body: _doc('d1', 'receipt')),
        (status: 200, body: _doc('d1', 'receipt', status: 'reversed')),
      ],
      '/inventory/documents/d1/reverse': [(status: 201, body: _doc('d9', 'reversal'))],
      '/inventory/documents/d9': [(status: 200, body: _doc('d9', 'reversal'))],
    });
    expect(find.text('Bu fiş irsaliye yerine geçmez.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stok-fis-iptal')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('stok-iptal-gerekce')), 'yanlış depo');
    await tester.tap(find.byKey(const ValueKey('stok-iptal-gerekce-confirm')));
    await tester.pumpAndSettle();
    expect(requestBodyFor(adapter, '/inventory/documents/d1/reverse')['reason'], 'yanlış depo');
    expect(find.text('STK-2026-00009'), findsWidgets);
  });

  testWidgets('yönetme yetkisi (adjust) olmayan fişi iptal edemez', (tester) async {
    await _pump(tester, user: _manager, initial: '/diger/stok/hareketler/d1', script: {
      '/inventory/documents/d1': [(status: 200, body: _doc('d1', 'receipt'))],
    });
    expect(find.byKey(const ValueKey('stok-fis-iptal')), findsNothing);
  });

  testWidgets('depolar: yönetici yeni depo açar', (tester) async {
    final adapter = await _pump(tester, user: _admin, initial: '/diger/stok/depolar', script: {
      '/inventory/warehouses': [
        (status: 200, body: _warehouses),
        (status: 201, body: {'id': 'w3', 'name': 'Şantiye Konteyner', 'address': '', 'notes': '', 'is_active': true, 'item_count': 0}),
        (status: 200, body: _warehouses),
      ],
    });
    expect(find.text('Merkez Depo'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stok-depo-ekle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('stok-depo-ad')), 'Şantiye Konteyner');
    await tester.tap(find.byKey(const ValueKey('stok-depo-kaydet')));
    await tester.pumpAndSettle();
    expect(requestBodyFor(adapter, '/inventory/warehouses')['name'], 'Şantiye Konteyner');
  });

  testWidgets('barkod okutunca malzemenin sayfası açılır; yoksa kart açmayı önerir', (tester) async {
    await _pump(tester, user: _admin, initial: '/diger/stok', scanned: '8690000000011', script: {
      '/inventory/items': [(status: 200, body: _items())],
      '/inventory/summary': [(status: 200, body: _summary())],
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
      '/inventory/items/by-barcode/8690000000011': [
        (status: 200, body: _item('i1', 'Kutu Profil 40x40', qty: 18)),
        (status: 404, body: {'error': 'malzeme bulunamadı'}),
      ],
      '/inventory/items/i1': [
        (status: 200, body: {'item': _item('i1', 'Kutu Profil 40x40', qty: 18), 'balances': [], 'documents': []}),
      ],
    });
    await tester.tap(find.byKey(const ValueKey('stok-barkod')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stok-kart-toplam')), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stok-barkod')));
    await tester.pumpAndSettle();
    expect(find.text('8690000000011 barkodlu malzeme yok.'), findsOneWidget);
    expect(find.text('Kart aç'), findsOneWidget);
  });

  testWidgets('malzeme seçicide okutulan barkod kartı doğrudan seçer', (tester) async {
    final items = _items();
    (items['items'] as List).first['barcode'] = '8690000000011';
    await _pump(tester, user: _admin, initial: '/diger/stok/fis/receipt?depo=w1', scanned: '8690000000011', script: {
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
      '/inventory/items': [(status: 200, body: items)],
    });
    await tester.tap(find.byKey(const ValueKey('stok-satir-ekle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stok-malzeme-okut')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stok-satir-miktar-i1')), findsOneWidget);
  });


  testWidgets('işlem menüsü telefon ekranında kesilmez: "Yeni Malzeme"ye ulaşılır', (tester) async {
    await _pump(tester, user: _admin, initial: '/diger/stok', script: {
      '/inventory/items': [(status: 200, body: _items())],
      '/inventory/summary': [(status: 200, body: _summary())],
      '/inventory/warehouses': [(status: 200, body: _warehouses)],
    });
    // 1.5.19'da menü ekranın ~yarısıyla sınırlıydı; iPhone'da "Sayım" kesiliyor,
    // "Yeni Malzeme" hiç görünmüyordu.
    await tester.binding.setSurfaceSize(const Size(390, 700));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stok-islem')));
    await tester.pumpAndSettle();
    final newItem = find.byKey(const ValueKey('stok-islem-yeni-malzeme'));
    await tester.ensureVisible(newItem);
    await tester.pumpAndSettle();
    await tester.tap(newItem);
    await tester.pumpAndSettle();
    expect(find.text('Yeni Malzeme'), findsOneWidget);
    expect(find.byKey(const ValueKey('stok-kart-ad')), findsOneWidget);
  });

}
