import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/presentation/collection_form_sheet.dart';
import 'package:arvend/features/projects/presentation/expense_form_sheet.dart';

import '../test_utils/fake_api_client.dart';

class _FakeAuth extends AuthController {
  _FakeAuth(this._user);
  final User _user;

  @override
  Future<User?> build() async => _user;
}

User _user(Set<String> permissions) => User(
      id: 'u1',
      organizationId: 'org1',
      username: 'test',
      fullName: 'Test Kullanıcı',
      role: UserRole.kullanici,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      organizationName: 'Deneme Yapı',
      permissions: permissions,
    );

Future<void> _open(
  WidgetTester tester,
  FakeHttpClientAdapter adapter,
  void Function(BuildContext context) open, {
  User? user,
}) async {
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        if (user != null) authControllerProvider.overrideWith(() => _FakeAuth(user)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(child: ElevatedButton(onPressed: () => open(context), child: const Text('Aç'))),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Aç'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  final save = find.widgetWithText(ElevatedButton, 'Kaydet');
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, Key field, String option) async {
  await tester.ensureVisible(find.byKey(field));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(field));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('geçersiz tutar/boş açıklama ile masraf formu gönderilemez, istek atılmaz', (tester) async {
    // Doğrulama mesajları + KDV seçimiyle form uzar: Kaydet ekranda kalsın.
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = FakeHttpClientAdapter(script: {});
    // Oturum açık (gerçek uygulamada sheet açılmadan önce /auth/me zaten
    // yüklenmiştir); bağlantı seçicisi izni yok -> tek istek bile atılmamalı.
    await _open(
      tester,
      adapter,
      (context) => showExpenseFormSheet(context, 'p1', currency: 'TRY'),
      user: _user({'projects.finance.manage'}),
    );

    // Açıklama boş, tutar boş -> Kaydet doğrulama hatalarını göstermeli.
    await _save(tester);

    expect(find.text('Açıklama gerekli'), findsOneWidget);
    expect(find.text('Geçerli bir tutar girin'), findsOneWidget);
    expect(adapter.calls, isEmpty, reason: 'form geçersizken hiçbir istek atılmamalı');

    // Açıklama var ama tutar <= 0 -> yine reddedilmeli.
    await tester.enterText(find.widgetWithText(TextFormField, 'Açıklama'), 'Çimento');
    await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '0');
    await _save(tester);

    expect(find.text('Geçerli bir tutar girin'), findsOneWidget);
    expect(adapter.calls, isEmpty);
  });

  testWidgets('masraf: ek iş + bütçe kalemi bağları ve not gönderilir; maliyet kodu kalemden gelir', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = FakeHttpClientAdapter(script: {
      '/projects/p1/change-orders': [
        (
          status: 200,
          body: {
            'change_orders': [
              {'id': 'co1', 'change_order_no': 'EK-001', 'change_type': 'addition', 'title': 'Mutfak dolabı', 'status': 'approved', 'grand_total': 96000, 'currency': 'TRY', 'created_at': '2026-09-06T08:00:00Z'},
              {'id': 'co2', 'change_order_no': 'EK-002', 'change_type': 'addition', 'title': 'Eski revizyon', 'status': 'superseded', 'grand_total': 1, 'currency': 'TRY', 'created_at': '2026-09-06T08:00:00Z'},
            ],
          },
        ),
      ],
      '/projects/p1/budget/lines': [
        (
          status: 200,
          body: {
            'budget_lines': [
              {'id': 'bl1', 'cost_code_id': 'cc2', 'cost_code_code': '03.01', 'cost_code_name': 'Kaba İnşaat', 'description': 'Alçıpan işleri', 'original_amount': 100000},
            ],
          },
        ),
      ],
      '/organization/cost-codes': [
        (
          status: 200,
          body: {
            'cost_codes': [
              {'id': 'cc1', 'code': '01.01', 'name': 'Genel Giderler', 'is_active': true},
              {'id': 'cc2', 'code': '03.01', 'name': 'Kaba İnşaat', 'is_active': true},
            ],
          },
        ),
      ],
      '/projects/p1/expenses': [
        (
          status: 201,
          body: {'id': 'e1', 'category': 'material', 'description': 'Alçıpan', 'amount': 1250.5, 'currency': 'TRY', 'expense_date': '2026-09-29', 'created_at': '2026-09-29T08:00:00Z', 'approval_status': 'pending'},
        ),
      ],
    });
    await _open(
      tester,
      adapter,
      (context) => showExpenseFormSheet(context, 'p1', currency: 'TRY'),
      user: _user({
        'projects.finance.read',
        'projects.finance.manage',
        'projects.budget.read',
        'organization.cost_codes.read',
      }),
    );

    expect(find.text('Bağlantılar (opsiyonel)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Açıklama'), 'Alçıpan');
    await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '1250,5');
    await _pick(tester, const ValueKey('masraf-ek-is'), 'EK-001 · Mutfak dolabı');
    // Yerine yenisi gelmiş ek iş seçilemez.
    await tester.tap(find.byKey(const ValueKey('masraf-ek-is')));
    await tester.pumpAndSettle();
    expect(find.text('EK-002 · Eski revizyon'), findsNothing);
    await tester.tap(find.text('EK-001 · Mutfak dolabı').last);
    await tester.pumpAndSettle();
    await _pick(tester, const ValueKey('masraf-butce-kalemi'), 'Alçıpan işleri (03.01)');
    expect(find.text('Bütçe kaleminden gelir.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Not (opsiyonel)'), 'Depoya teslim');
    await _save(tester);

    final body = adapter.requestBodies[adapter.calls.indexOf('/projects/p1/expenses')] as Map<String, dynamic>;
    expect(body['amount'], 1250.5);
    expect(body['currency'], 'TRY');
    expect(body['change_order_id'], 'co1');
    expect(body['budget_line_id'], 'bl1');
    expect(body['cost_code_id'], 'cc2');
    expect(body['notes'], 'Depoya teslim');
    expect(body['idempotency_key'], startsWith('exp-'));
    // Masraf onay bekleyerek doğar: form kapanınca bunu söyler.
    expect(find.text('Masraf onaya gönderildi.'), findsOneWidget);
  });

  testWidgets('masraf KDV: varsayılan Belirtilmedi; oran seçilince canlı KDV hariç/KDV önizlemesi, vat_rate gider', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = FakeHttpClientAdapter(script: {
      '/projects/p1/expenses': [
        (
          status: 201,
          body: {'id': 'e1', 'category': 'material', 'description': 'Çimento', 'amount': 1200, 'currency': 'TRY', 'expense_date': '2026-10-07', 'created_at': '2026-10-07T08:00:00Z', 'approval_status': 'pending', 'vat_rate': 20, 'vat_amount': 200, 'net_amount': 1000},
        ),
      ],
    });
    await _open(
      tester,
      adapter,
      (context) => showExpenseFormSheet(context, 'p1', currency: 'TRY'),
      user: _user({'projects.finance.manage'}),
    );

    ChoiceChip chip(String key) => tester.widget<ChoiceChip>(find.byKey(ValueKey('masraf-kdv-$key')));
    expect(chip('belirtilmedi').selected, isTrue, reason: 'varsayılan: belirtilmedi');
    for (final label in ['Belirtilmedi', 'KDV yok (%0)', '%1', '%10', '%20']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget, reason: label);
    }
    expect(find.byKey(const ValueKey('masraf-kdv-onizleme')), findsNothing);

    await tester.enterText(find.widgetWithText(TextFormField, 'Açıklama'), 'Çimento');
    await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '120.000');
    await _tapKey(tester, const ValueKey('masraf-kdv-20'));
    expect(chip('20').selected, isTrue);
    expect(find.text('KDV hariç: 100.000,00 TL · KDV: 20.000,00 TL'), findsOneWidget);

    // Önizleme tutarla birlikte canlı değişir.
    await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '1.200');
    await tester.pump();
    expect(find.text('KDV hariç: 1.000,00 TL · KDV: 200,00 TL'), findsOneWidget);
    await _tapKey(tester, const ValueKey('masraf-kdv-10'));
    expect(find.text('KDV hariç: 1.090,91 TL · KDV: 109,09 TL'), findsOneWidget);
    await _tapKey(tester, const ValueKey('masraf-kdv-0'));
    expect(find.text('KDV hariç: 1.200,00 TL · KDV: 0,00 TL'), findsOneWidget);
    await _tapKey(tester, const ValueKey('masraf-kdv-20'));
    await _save(tester);

    final body = adapter.requestBodies.single as Map<String, dynamic>;
    expect(adapter.methods.single, 'POST');
    expect(body['amount'], 1200);
    expect(body['vat_rate'], 20);
    expect(find.text('Masraf onaya gönderildi.'), findsOneWidget);
  });

  testWidgets('masraf KDV: Belirtilmedi ise vat_rate hiç gönderilmez (sunucu NULL yazar); KDV yok %0 gider', (
    tester,
  ) async {
    Map<String, dynamic> created(String id) => {'id': id, 'category': 'material', 'description': 'Çimento', 'amount': 500, 'currency': 'TRY', 'expense_date': '2026-10-07', 'created_at': '2026-10-07T08:00:00Z', 'approval_status': 'pending'};
    final adapter = FakeHttpClientAdapter(script: {
      '/projects/p1/expenses': [(status: 201, body: created('e1')), (status: 201, body: created('e2'))],
    });
    for (final (chipKey, expected) in [('belirtilmedi', null), ('0', 0)]) {
      await _open(
        tester,
        adapter,
        (context) => showExpenseFormSheet(context, 'p1', currency: 'TRY'),
        user: _user({'projects.finance.manage'}),
      );
      await tester.enterText(find.widgetWithText(TextFormField, 'Açıklama'), 'Çimento');
      await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '500');
      // Önce bir oran seçip sonra vazgeçmek de "belirtilmedi"ye döner.
      await _tapKey(tester, const ValueKey('masraf-kdv-20'));
      await _tapKey(tester, ValueKey('masraf-kdv-$chipKey'));
      await _save(tester);
      final body = adapter.requestBodies.last as Map<String, dynamic>;
      if (expected == null) {
        expect(body.containsKey('vat_rate'), isFalse, reason: 'alan yok = belirtilmedi (eski sunucuyu da bozmaz)');
      } else {
        expect(body['vat_rate'], expected);
      }
    }
  });

  testWidgets('masraf: izin yoksa bağlantı seçicileri yüklenmez (gereksiz 403 yok)', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {});
    await _open(
      tester,
      adapter,
      (context) => showExpenseFormSheet(context, 'p1', currency: 'TRY'),
      user: _user({'projects.finance.manage'}),
    );
    expect(find.text('Bağlantılar (opsiyonel)'), findsNothing);
    expect(adapter.calls, isEmpty);
  });

  testWidgets('tahsilat: açık ödeme planı kalemine bağlanır, iptal edilmiş kalem sunulmaz', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = FakeHttpClientAdapter(script: {
      '/projects/p1/payment-plan': [
        (
          status: 200,
          body: {
            'planned_total': 500000,
            'items': [
              {'id': 'pi1', 'name': 'Avans', 'planned_amount': 250000, 'collected_amount': 100000, 'remaining_amount': 150000, 'status': 'partial'},
              {'id': 'pi2', 'name': 'Eski kalem', 'planned_amount': 1, 'collected_amount': 0, 'remaining_amount': 1, 'status': 'cancelled'},
            ],
          },
        ),
      ],
      '/projects/p1/collections': [
        (
          status: 201,
          body: {'id': 'c1', 'amount': 150000, 'currency': 'TRY', 'received_date': '2026-09-29', 'payment_plan_item_id': 'pi1', 'created_at': '2026-09-29T08:00:00Z'},
        ),
      ],
    });
    await _open(
      tester,
      adapter,
      (context) => showCollectionFormSheet(context, 'p1', currency: 'TRY'),
      user: _user({'projects.finance.read', 'projects.finance.manage'}),
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '150000');
    await tester.tap(find.byKey(const ValueKey('tahsilat-plan-kalemi')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Eski kalem'), findsNothing);
    await tester.tap(find.textContaining('Avans · kalan').last);
    await tester.pumpAndSettle();
    await _save(tester);

    final body = adapter.requestBodies[adapter.calls.indexOf('/projects/p1/collections')] as Map<String, dynamic>;
    expect(body['amount'], 150000);
    expect(body['payment_plan_item_id'], 'pi1');
    expect(body['idempotency_key'], startsWith('col-'));
  });

  testWidgets('tahsilat: plan kalemi seçilmezse null gider', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/projects/p1/collections': [
        (
          status: 201,
          body: {'id': 'c1', 'amount': 10, 'currency': 'TRY', 'received_date': '2026-09-29', 'created_at': '2026-09-29T08:00:00Z'},
        ),
      ],
    });
    await _open(
      tester,
      adapter,
      (context) => showCollectionFormSheet(context, 'p1', currency: 'TRY'),
      user: _user({'projects.finance.manage'}),
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '10');
    await _save(tester);
    final body = adapter.requestBodies.last as Map<String, dynamic>;
    expect(body.containsKey('payment_plan_item_id'), isTrue);
    expect(body['payment_plan_item_id'], isNull);
  });

  testWidgets('tahsilat: Türkçe tutar "64.000" altmış dört bin, "1.250,50" bin iki yüz elli gider', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/projects/p1/collections': [
        (
          status: 201,
          body: {'id': 'c1', 'amount': 64000, 'currency': 'TRY', 'received_date': '2026-09-29', 'created_at': '2026-09-29T08:00:00Z'},
        ),
        (
          status: 201,
          body: {'id': 'c2', 'amount': 1250.5, 'currency': 'TRY', 'received_date': '2026-09-29', 'created_at': '2026-09-29T08:00:00Z'},
        ),
      ],
    });
    for (final (input, expected) in [('64.000', 64000), ('1.250,50', 1250.5)]) {
      await _open(
        tester,
        adapter,
        (context) => showCollectionFormSheet(context, 'p1', currency: 'TRY'),
        user: _user({'projects.finance.manage'}),
      );
      await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), input);
      await _save(tester);
      final body = adapter.requestBodies.last as Map<String, dynamic>;
      expect(body['amount'], expected, reason: input);
    }
  });
}
