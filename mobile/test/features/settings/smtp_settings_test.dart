import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/settings/data/settings_repository.dart';
import 'package:arvend/features/settings/domain/smtp_settings.dart';
import 'package:arvend/features/settings/settings_routes.dart';

import '../../test_utils/fake_api_client.dart';
import 'settings_fakes.dart';

Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(400, 2400) * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

void main() {
  group('model + repository', () {
    test('response never carries the stored password, only password_set', () {
      final s = SmtpSettings.fromJson({
        'host': 'smtp.x.com',
        'port': 0,
        'username': 'u',
        'password_set': true,
        'from_email': 'a@b.com',
        'from_name': 'A',
        'use_tls': true,
        'configured': true,
      });
      expect(s.passwordSet, isTrue);
      expect(s.portOrDefault, 587);
    });

    test('empty password is sent as null (= keep the stored one)', () {
      const input = SmtpSettingsInput(
        host: ' smtp.x.com ',
        port: 465,
        username: 'u',
        password: '',
        fromEmail: 'a@b.com',
        fromName: 'A',
        useTls: false,
      );
      final json = input.toJson();
      expect(json['password'], isNull);
      expect(json['host'], 'smtp.x.com');
      expect(json['port'], 465);
    });

    test('repository hits /settings/smtp and /settings/smtp/test', () async {
      final smtpJson = {
        'host': 'h',
        'port': 587,
        'username': '',
        'password_set': false,
        'from_email': 'a@b.com',
        'from_name': '',
        'use_tls': true,
        'configured': true,
      };
      final adapter = FakeHttpClientAdapter(script: {
        '/settings/smtp': [(status: 200, body: smtpJson), (status: 200, body: smtpJson)],
        '/settings/smtp/test': [(status: 200, body: {'ok': true})],
      });
      final repo = SettingsRepository(await buildFakeApiClient(adapter));
      await repo.smtp();
      await repo.updateSmtp(const SmtpSettingsInput(
        host: 'h',
        port: 587,
        username: '',
        password: 'gizli',
        fromEmail: 'a@b.com',
        fromName: '',
        useTls: true,
      ));
      await repo.sendTestEmail(' test@ornek.com ');
      expect(adapter.calls, ['/settings/smtp', '/settings/smtp', '/settings/smtp/test']);
      expect((adapter.requestBodies[1] as Map)['password'], 'gizli');
      expect(adapter.requestBodies[2], {'to': 'test@ornek.com'});
    });
  });

  group('screen', () {
    testWidgets('non-admin role never sees it, even with a per-user grant (fail-closed)', (tester) async {
      final repo = FakeSettingsRepository();
      await _pump(tester, smtpApp(user: nonAdminWithSettingsPerm, repo: repo));
      expect(find.textContaining('yalnızca Sahip ve Yönetici'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('owner: stored password is never shown, empty password keeps it', (tester) async {
      final repo = FakeSettingsRepository();
      await _pump(tester, smtpApp(user: settingsOwner, repo: repo));
      expect(find.text('Yapılandırıldı'), findsOneWidget);
      expect(find.text('Şifre (değiştirmek için doldur)'), findsOneWidget);
      final pw = tester.widget<TextFormField>(_field('Şifre (değiştirmek için doldur)'));
      expect(pw.controller!.text, isEmpty);

      await tester.enterText(_field('Gönderen Adı'), 'Arvend Yapı Teklif');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.saved.single.password, isEmpty);
      expect(repo.saved.single.toJson()['password'], isNull);
      expect(repo.saved.single.fromName, 'Arvend Yapı Teklif');
      expect(find.text('Kaydedildi.'), findsOneWidget);
    });

    testWidgets('new password is sent once and the field is cleared', (tester) async {
      final repo = FakeSettingsRepository();
      await _pump(tester, smtpApp(user: settingsOwner, repo: repo));
      await tester.enterText(_field('Şifre (değiştirmek için doldur)'), 'yeni-sifre');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.saved.single.password, 'yeni-sifre');
      final pw = tester.widget<TextFormField>(_field('Şifre (değiştirmek için doldur)'));
      expect(pw.controller!.text, isEmpty);
    });

    testWidgets('validation: host, port range, sender e-mail', (tester) async {
      final repo = FakeSettingsRepository();
      await _pump(tester, smtpApp(user: settingsOwner, repo: repo));
      await tester.enterText(_field('Sunucu (Host) *'), '');
      await tester.enterText(_field('Port *'), '70000');
      await tester.enterText(_field('Gönderen E-posta *'), 'gecersiz');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Sunucu adresi zorunludur'), findsOneWidget);
      expect(find.text('1 ile 65535 arasında bir port gir'), findsOneWidget);
      expect(find.text('Geçerli bir e-posta adresi gir'), findsOneWidget);
      expect(repo.saved, isEmpty);
    });

    testWidgets('test e-mail: requires an address, reports success and unsaved-change warning', (tester) async {
      final repo = FakeSettingsRepository();
      await _pump(tester, smtpApp(user: settingsOwner, repo: repo));
      await tester.tap(find.text('Test Et'));
      await tester.pumpAndSettle();
      expect(find.text('Test e-postası için bir adres gir.'), findsOneWidget);

      await tester.enterText(_field('Sunucu (Host) *'), 'smtp.baska.com');
      await tester.pump();
      expect(find.textContaining('Kaydedilmemiş değişikliklerin var'), findsOneWidget);

      await tester.enterText(_field('Alıcı e-posta'), 'deneme@ornek.com');
      await tester.tap(find.text('Test Et'));
      await tester.pumpAndSettle();
      expect(repo.testRecipients, ['deneme@ornek.com']);
      expect(find.text('Test e-postası deneme@ornek.com adresine gönderildi.'), findsOneWidget);
    });

    testWidgets('test failure shows the backend message', (tester) async {
      final repo = FakeSettingsRepository()
        ..testError = const ApiException(statusCode: 400, message: 'gönderilemedi: bağlantı reddedildi', kind: ApiErrorKind.badRequest);
      await _pump(tester, smtpApp(user: settingsOwner, repo: repo));
      await tester.enterText(_field('Alıcı e-posta'), 'deneme@ornek.com');
      await tester.tap(find.text('Test Et'));
      await tester.pumpAndSettle();
      expect(find.text('gönderilemedi: bağlantı reddedildi'), findsOneWidget);
    });

    testWidgets('read-only admin: fields locked, no password field, no save/test', (tester) async {
      final repo = FakeSettingsRepository();
      await _pump(tester, smtpApp(user: settingsReader, repo: repo));
      expect(find.textContaining('yalnızca görüntüleyebilirsin'), findsOneWidget);
      expect(find.text('Kaydet'), findsNothing);
      expect(find.text('Test Et'), findsNothing);
      expect(find.textContaining('Şifre ('), findsNothing);
      expect(tester.widget<TextFormField>(_field('Sunucu (Host) *')).enabled, isFalse);
      expect(find.text('Kayıtlı'), findsOneWidget);
    });

    testWidgets('403 on load shows an access message, not a crash', (tester) async {
      final repo = FakeSettingsRepository()
        ..loadError = const ApiException(statusCode: 403, message: 'yetkisiz', kind: ApiErrorKind.forbidden);
      await _pump(tester, smtpApp(user: settingsOwner, repo: repo));
      expect(find.textContaining('yalnızca Sahip ve Yönetici'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('route + menu descriptor', () {
    expect(settingsMenuEntries.single.route, '/diger/eposta-ayarlari');
    expect(settingsMenuEntries.single.permission, 'organization.settings.read');
    expect(settingsRoutes, hasLength(1));
    expect(UserRole.admin.wireValue, 'admin');
  });
}
