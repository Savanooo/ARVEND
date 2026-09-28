import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/theme/app_colors.dart';
import 'package:arvend/core/widgets/app_data_row.dart';
import 'package:arvend/core/widgets/quick_action_button.dart';
import 'package:arvend/features/suppliers/suppliers_routes.dart';

import 'suppliers_test_support.dart';

/// Tedarikçi detayının ortak düzeni (iletişim kısayolları, sağa yaslı
/// satırlar) ve kayıt sürerken formun kapatılamaması.
void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  Future<void> pump(WidgetTester tester, FakeSuppliersRepository repo, String location) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(480, 1800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildSuppliersApp(user: ownerUser, repo: repo, initialLocation: location));
    await tester.pumpAndSettle();
  }

  testWidgets('detay: Ara / E-posta kısayolları başlık altında; telefon ve e-posta mavi bağlantı değil', (tester) async {
    await pump(tester, FakeSuppliersRepository(), supplierDetailPath('s1'));
    expect(find.widgetWithText(QuickActionButton, 'Ara'), findsOneWidget);
    expect(find.widgetWithText(QuickActionButton, 'E-posta'), findsOneWidget);
    // Satırlar ortak AppDataRow düzeninde; hiçbir metin bilgi-mavisiyle çizilmez.
    expect(find.byType(AppDataRow), findsWidgets);
    final blue = find.byWidgetPredicate((w) => w is Text && w.style?.color == AppColors.info);
    expect(blue, findsNothing);
    expect(find.text('0216 555 10 20'), findsOneWidget);
  });

  testWidgets('yalnızca olan iletişim için kısayol; hiç yoksa hiç yok', (tester) async {
    await pump(tester, FakeSuppliersRepository(), supplierDetailPath('s2'));
    expect(find.widgetWithText(QuickActionButton, 'Ara'), findsOneWidget);
    expect(find.widgetWithText(QuickActionButton, 'E-posta'), findsNothing);

    await pump(tester, FakeSuppliersRepository(), supplierDetailPath('s4'));
    expect(find.byType(QuickActionButton), findsNothing);
  });

  testWidgets('Unvan alanı uzun ünvanlar için büyür (en çok 3 satır)', (tester) async {
    await pump(tester, FakeSuppliersRepository(), supplierDetailPath('s1'));
    await tester.tap(find.byTooltip('Düzenle'));
    await tester.pumpAndSettle();
    final editable = tester.widget<EditableText>(
      find.descendant(of: find.byKey(const ValueKey('supplier-legal-name')), matching: find.byType(EditableText)),
    );
    expect(editable.maxLines, 3);
    expect(editable.minLines, 1);
  });

  testWidgets('kayıt sürerken form kapatılamaz; bitince liste tazelenir', (tester) async {
    final gate = Completer<void>();
    final repo = FakeSuppliersRepository()..writeGate = gate;
    await pump(tester, repo, kSuppliersPath);
    await tester.tap(find.text('Yeni Tedarikçi'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('supplier-code')), 'TED-010');
    await tester.enterText(find.byKey(const ValueKey('supplier-legal-name')), 'Anadolu Hırdavat Ltd. Şti.');
    await tester.tap(find.text('Kaydet'));
    await tester.pump();

    // Android geri hareketi ve sayfa dışına dokunma engellenir.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(find.byKey(const ValueKey('supplier-code')), findsOneWidget);
    expect(find.text('Kaydediliyor, lütfen bitmesini bekle.'), findsOneWidget);

    final listCallsBefore = repo.calls.where((c) => c == 'list').length;
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('supplier-code')), findsNothing);
    expect(repo.calls.where((c) => c == 'list').length, greaterThan(listCallsBefore));
    expect(find.text('Anadolu Hırdavat Ltd. Şti.'), findsOneWidget);
  });
}
