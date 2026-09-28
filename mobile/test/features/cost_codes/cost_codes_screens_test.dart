import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/cost_codes/cost_codes_routes.dart';
import 'package:arvend/features/cost_codes/domain/cost_code.dart';
import 'package:arvend/features/cost_codes/presentation/widgets/cost_code_ui.dart';

import 'cost_codes_test_support.dart';

Future<void> _pumpApp(
  WidgetTester tester, {
  required User user,
  required FakeCostCodesRepository repo,
  String location = kCostCodesPath,
}) async {
  // Uzun gruplu liste kaydırmadan test edilebilsin diye yüksek yüzey.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(480, 2400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(buildCostCodesApp(user: user, repo: repo, initialLocation: location));
  await tester.pumpAndSettle();
}

double _y(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

void main() {
  group('list', () {
    testWidgets('owner sees active codes grouped by category in Turkish order, uncategorized last', (tester) async {
      final repo = FakeCostCodesRepository();
      await _pumpApp(tester, user: ccOwnerUser, repo: repo);

      expect(find.text('8 kod · 5 kategori'), findsOneWidget);
      final headers = ['Ekipman', 'İşçilik', 'Malzeme', 'Taşeron', kUncategorizedLabel];
      for (final h in headers) {
        expect(find.text(h), findsOneWidget, reason: h);
      }
      for (var i = 1; i < headers.length; i++) {
        expect(_y(tester, headers[i - 1]) < _y(tester, headers[i]), isTrue, reason: '${headers[i - 1]} < ${headers[i]}');
      }
      // "malzeme " yazımı "Malzeme" grubuna katılır.
      expect(_y(tester, 'Malzeme') < _y(tester, 'Alçı Sıva'), isTrue);
      expect(_y(tester, 'Alçı Sıva') < _y(tester, 'Taşeron'), isTrue);
      // Arşivlenmiş gizli.
      expect(find.text('Tuğla'), findsNothing);
      expect(find.text('Yeni Maliyet Kodu'), findsOneWidget);
      expect(find.text(kCostCodesReadOnlyText), findsNothing);
    });

    testWidgets('search and archive filter', (tester) async {
      await _pumpApp(tester, user: ccOwnerUser, repo: FakeCostCodesRepository());

      await tester.enterText(find.byType(TextField), 'işçilik');
      await tester.pumpAndSettle();
      expect(find.text('Kalıp İşçiliği'), findsOneWidget);
      expect(find.text('Demir Bağlama İşçiliği'), findsOneWidget);
      expect(find.text('Hazır Beton'), findsNothing);
      expect(find.text('2 sonuç'), findsOneWidget);

      await tester.tap(find.byTooltip('Aramayı temizle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arşiv (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Tuğla'), findsOneWidget);
      expect(find.text('Arşivlendi'), findsOneWidget);
      expect(find.text('Hazır Beton'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('Arama kriterlerine uyan kod yok.'), findsOneWidget);
    });

    testWidgets('read-only user: notice, no create button', (tester) async {
      await _pumpApp(tester, user: ccReadOnlyUser, repo: FakeCostCodesRepository());
      expect(find.text(kCostCodesReadOnlyText), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Hazır Beton'), findsOneWidget);
    });

    testWidgets('non-admin finance with .manage can create (no requireAdmin)', (tester) async {
      await _pumpApp(tester, user: ccFinanceUser, repo: FakeCostCodesRepository());
      expect(find.text('Yeni Maliyet Kodu'), findsOneWidget);
    });

    for (final (name, user) in [('no permission', ccNoAccessUser), ('empty permission set', ccEmptyPermissionsUser)]) {
      testWidgets('$name: lock message and no request', (tester) async {
        final repo = FakeCostCodesRepository();
        await _pumpApp(tester, user: user, repo: repo);
        expect(find.text(kCostCodesNoAccessText), findsOneWidget);
        expect(repo.calls, isEmpty);
      });
    }

    testWidgets('server 403 shows the no-access message, not a crash', (tester) async {
      await _pumpApp(tester, user: ccOwnerUser, repo: FakeCostCodesRepository()..listError = forbidden);
      expect(tester.takeException(), isNull);
      expect(find.text(kCostCodesNoAccessText), findsOneWidget);
    });

    testWidgets('empty catalog message', (tester) async {
      await _pumpApp(tester, user: ccOwnerUser, repo: FakeCostCodesRepository(const []));
      expect(
        find.text(
          'Henüz hiç maliyet kodu oluşturulmamış. Bütçe kalemleri ve taahhütler bu kodlarla sınıflandırılır.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping a row opens its detail', (tester) async {
      final repo = FakeCostCodesRepository();
      await _pumpApp(tester, user: ccOwnerUser, repo: repo);
      await tester.tap(find.text('Hazır Beton'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('get:c5'));
      expect(find.text('C30/37 pompalı hazır beton'), findsOneWidget);
    });
  });

  group('detail', () {
    testWidgets('owner: fields, status and actions', (tester) async {
      await _pumpApp(tester, user: ccOwnerUser, repo: FakeCostCodesRepository(), location: costCodeDetailPath('c5'));
      expect(find.text('MLZ-001'), findsWidgets);
      expect(find.text('Hazır Beton'), findsWidgets);
      expect(find.text('Malzeme'), findsOneWidget);
      expect(find.text('C30/37 pompalı hazır beton'), findsOneWidget);
      expect(find.text('Aktif'), findsWidgets);
      expect(find.byTooltip('Düzenle'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Arşivle'), findsOneWidget);
    });

    testWidgets('read-only: no edit / archive', (tester) async {
      await _pumpApp(tester, user: ccReadOnlyUser, repo: FakeCostCodesRepository(), location: costCodeDetailPath('c5'));
      expect(find.text(kCostCodesReadOnlyText), findsOneWidget);
      expect(find.byTooltip('Düzenle'), findsNothing);
      expect(find.text('Arşivle'), findsNothing);
    });

    testWidgets('uncategorized code shows a dash and "Açıklama yok." when empty', (tester) async {
      await _pumpApp(tester, user: ccOwnerUser, repo: FakeCostCodesRepository(), location: costCodeDetailPath('c4'));
      expect(find.text('Açıklama yok.'), findsOneWidget);
      await _pumpApp(tester, user: ccOwnerUser, repo: FakeCostCodesRepository(), location: costCodeDetailPath('c2'));
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('archive with confirmation (cancel then confirm), then reactivate', (tester) async {
      final repo = FakeCostCodesRepository();
      await _pumpApp(tester, user: ccOwnerUser, repo: repo, location: costCodeDetailPath('c5'));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Arşivle'));
      await tester.pumpAndSettle();
      expect(find.text('Maliyet Kodunu Arşivle'), findsOneWidget);
      expect(find.textContaining('yeni bütçe/taahhüt kayıtlarında seçilemeyecek'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((c) => c.startsWith('archive')), isEmpty);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Arşivle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Arşivle'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('archive:c5'));
      expect(find.text('Maliyet kodu arşivlendi.'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Etkinleştir'));
      await tester.pumpAndSettle();
      expect(find.text('Maliyet Kodunu Etkinleştir'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Etkinleştir'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('reactivate:c5'));
    });

    testWidgets('a 403 on archive becomes a clear message', (tester) async {
      final repo = FakeCostCodesRepository()..writeError = forbidden;
      await _pumpApp(tester, user: ccOwnerUser, repo: repo, location: costCodeDetailPath('c5'));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Arşivle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Arşivle'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Bu işlem için yetkin yok.'), findsOneWidget);
    });
  });

  group('form', () {
    testWidgets('create: required fields, category quick-pick, posts code + fields', (tester) async {
      final repo = FakeCostCodesRepository();
      await _pumpApp(tester, user: ccOwnerUser, repo: repo);

      await tester.tap(find.text('Yeni Maliyet Kodu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Maliyet kodu zorunludur'), findsOneWidget);
      expect(find.text('Maliyet kodu adı zorunludur'), findsOneWidget);
      expect(repo.created, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('cost-code-code')), 'MLZ-010');
      await tester.enterText(find.byKey(const ValueKey('cost-code-name')), 'Kum');
      // Mevcut kategoriler çip olarak sunulur; seçince alan dolar.
      expect(find.widgetWithText(ChoiceChip, 'İşçilik'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Malzeme'));
      await tester.pumpAndSettle();
      final category = tester.widget<TextField>(
        find.descendant(of: find.byKey(const ValueKey('cost-code-category')), matching: find.byType(TextField)),
      );
      expect(category.controller!.text, 'Malzeme');

      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      final (code, input) = repo.created.single;
      expect(code, 'MLZ-010');
      expect(input.name, 'Kum');
      expect(input.category, 'Malzeme');
      expect(find.text('"MLZ-010" eklendi.'), findsOneWidget);
      expect(find.text('Kum'), findsOneWidget);
    });

    testWidgets('edit: code locked with explanation; update sends name/category/description', (tester) async {
      final repo = FakeCostCodesRepository();
      await _pumpApp(tester, user: ccOwnerUser, repo: repo, location: costCodeDetailPath('c5'));

      await tester.tap(find.byTooltip('Düzenle'));
      await tester.pumpAndSettle();
      expect(find.text('Maliyet Kodunu Düzenle'), findsOneWidget);
      final codeField = tester.widget<TextField>(
        find.descendant(of: find.byKey(const ValueKey('cost-code-code')), matching: find.byType(TextField)),
      );
      expect(codeField.enabled, isFalse);
      expect(find.textContaining('Kod oluşturulduktan sonra değiştirilemez'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('cost-code-name')), 'Hazır Beton C35');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      final (id, input) = repo.updated.single;
      expect(id, 'c5');
      expect(input.name, 'Hazır Beton C35');
      expect(input.category, 'Malzeme');
      expect(input.description, 'C30/37 pompalı hazır beton');
      expect(input.toUpdateJson().containsKey('code'), isFalse);
      expect(find.text('Maliyet kodu kaydedildi.'), findsOneWidget);
      expect(find.text('Hazır Beton C35'), findsWidgets);
    });

    testWidgets('duplicate code (409) stays in the sheet', (tester) async {
      final repo = FakeCostCodesRepository()
        ..writeError = const ApiException(
          statusCode: 409,
          message: 'bu kod bu firmada zaten kullanılıyor',
          kind: ApiErrorKind.conflict,
        );
      await _pumpApp(tester, user: ccOwnerUser, repo: repo);
      await tester.tap(find.text('Yeni Maliyet Kodu'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('cost-code-code')), 'MLZ-001');
      await tester.enterText(find.byKey(const ValueKey('cost-code-name')), 'Kopya');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('bu kod bu firmada zaten kullanılıyor'), findsOneWidget);
    });
  });

  group('routes & menu descriptor', () {
    test('menu entry', () {
      final entry = costCodesMenuEntries.single;
      expect(entry.label, 'Maliyet Kodları');
      expect(entry.route, '/diger/maliyet-kodlari');
      expect(entry.permission, 'organization.cost_codes.read');
      expect(entry.icon, Icons.sell_outlined);
    });

    test('routes are relative to /diger', () {
      expect(costCodesRoutes, hasLength(1));
      expect(costCodeDetailPath('c1'), '/diger/maliyet-kodlari/c1');
    });
  });
}
