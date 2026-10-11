import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/onboarding/data/onboarding_repository.dart';
import 'package:arvend/features/onboarding/domain/onboarding_state.dart';
import 'package:arvend/features/onboarding/presentation/onboarding_step_forms.dart';
import 'package:arvend/features/onboarding/presentation/organization_settings_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart' show FakeAuth;

/// Firma Ayarları izne bakar (backend requireAdmin + organization.settings.
/// read/manage): görüntüleme izni yoksa kilit ekranı ve istek yok; yalnızca
/// görüntüleyebilen kişiye formlar salt-okur (Kaydet yok). Eskiden ekran
/// kaba role bakıyordu: izin alınmış Yönetici hata ekranı, salt-okur kişi
/// Kaydet'te 403 görüyordu. Finans sekmesindeki firma IBAN'ı da kaydetmeden
/// önce doğrulanır (teklif PDF'inde müşteriye gider).

User _admin(Set<String> permissions) => User(
      id: 'u1',
      organizationId: 'org1',
      username: 'yonetici',
      fullName: 'Yönetici',
      role: UserRole.admin,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      organizationName: 'Deneme Yapı',
      permissions: permissions,
    );

const _state = {
  'onboarding_completed': true,
  'onboarding_step': 'completed',
  'profile': {'authorized_person': 'Ayşe Yılmaz', 'legal_name': 'Deneme Yapı Ltd.'},
  'commercial': {'default_currency': 'TRY', 'offer_prefix': 'TKF', 'offer_validity_days': 30, 'iban_set': true},
};

Future<FakeHttpClientAdapter> _pump(WidgetTester tester, User user) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/organization/settings': [(status: 200, body: _state)],
  });
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => FakeAuth(user)),
    ],
    child: const MaterialApp(home: OrganizationSettingsScreen()),
  ));
  await tester.pumpAndSettle();
  return adapter;
}

void main() {
  group('OrganizationSettingsScreen izinleri', () {
    testWidgets('düzenleme izni varsa formlar açık, Kaydet görünür', (tester) async {
      final adapter = await _pump(tester, _admin({'organization.settings.read', 'organization.settings.manage'}));

      expect(adapter.calls, ['/organization/settings']);
      expect(find.byType(ReadOnlyNotice), findsNothing);
      expect(find.text('Kaydet'), findsOneWidget);
      expect(find.text('Ayşe Yılmaz'), findsOneWidget);
    });

    testWidgets('yalnızca görüntüleme izni: salt-okur not, Kaydet yok, alana yazılamaz', (tester) async {
      final adapter = await _pump(tester, _admin({'organization.settings.read'}));

      expect(find.byType(ReadOnlyNotice), findsOneWidget);
      expect(find.textContaining('yalnızca görüntüleyebilirsin'), findsOneWidget);
      expect(find.text('Kaydet'), findsNothing);
      // Alan kilitli: dokununca odaklanmaz (klavye açılmaz), istek gitmez.
      final field = find.widgetWithText(TextFormField, 'Ayşe Yılmaz');
      await tester.tap(field, warnIfMissed: false);
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)));
      expect(editable.focusNode.hasFocus, isFalse);
      expect(editable.focusNode.canRequestFocus, isFalse);
      expect(adapter.calls, ['/organization/settings']);
    });

    testWidgets('görüntüleme izni yoksa kilit ekranı, istek atılmaz', (tester) async {
      final adapter = await _pump(tester, _admin({'projects.read'}));

      expect(find.byType(NoAccessView), findsOneWidget);
      expect(find.textContaining('Firma ayarlarını görüntüleme'), findsOneWidget);
      expect(adapter.calls, isEmpty);
    });

    testWidgets('kaba rol admin değilse izin olsa da kilit ekranı (sunucu requireAdmin)', (tester) async {
      final user = User(
        id: 'u2',
        username: 'uye',
        fullName: 'Üye',
        role: UserRole.kullanici,
        isActive: true,
        mustChangePassword: false,
        onboardingCompleted: true,
        onboardingStep: 'completed',
        permissions: const {'organization.settings.read', 'organization.settings.manage'},
      );
      final adapter = await _pump(tester, user);

      expect(find.byType(NoAccessView), findsOneWidget);
      expect(adapter.calls, isEmpty);
    });
  });

  group('Finans: firma IBAN doğrulaması', () {
    Future<FakeHttpClientAdapter> pumpFinance(WidgetTester tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/settings/finance': [(status: 200, body: _state)],
      });
      final repo = OnboardingRepository(await buildFakeApiClient(adapter), basePath: '/organization/settings');
      await tester.binding.setSurfaceSize(const Size(400, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FinanceStepForm(
              repository: repo,
              initial: OrganizationCommercialSettings.fromJson(const {'iban_set': true, 'bank_name': 'Ziraat'}),
              onSaved: (_) {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return adapter;
    }

    testWidgets('eksik haneli IBAN kaydedilmez, sebebi yazılır', (tester) async {
      final adapter = await pumpFinance(tester);

      await tester.enterText(find.byKey(const ValueKey('finance-iban')), 'TR12 0006 1234');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Geçerli bir IBAN gir'), findsOneWidget);
      expect(adapter.calls, isEmpty);
    });

    testWidgets('boşluklu/küçük harfli geçerli IBAN normalize edilip gönderilir', (tester) async {
      final adapter = await pumpFinance(tester);

      await tester.enterText(find.byKey(const ValueKey('finance-iban')), 'tr33 0006 1005 1978 6457 8413 26');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      expect(adapter.calls, ['/organization/settings/finance']);
      expect((adapter.requestBodies.single as Map)['iban'], 'TR330006100519786457841326');
    });

    testWidgets('IBAN boş bırakılırsa gönderilmez (kayıtlı IBAN korunur)', (tester) async {
      final adapter = await pumpFinance(tester);

      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      expect(adapter.calls, ['/organization/settings/finance']);
      expect((adapter.requestBodies.single as Map).containsKey('iban'), isFalse);
    });
  });
}
