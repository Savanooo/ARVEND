@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/settings/domain/smtp_settings.dart';

import 'settings_fakes.dart';

/// E-posta (SMTP) ayarları ekran görüntüleri (360x800, PNG 720x1600):
///   flutter test --tags golden --update-goldens test/features/settings
void main() {
  setUpAll(loadAppFonts);

  final cases = <String, ({User user, SmtpSettings settings})>{
    'smtp_settings_owner_360x800': (user: settingsOwner, settings: sampleSmtp),
    'smtp_settings_readonly_360x800': (user: settingsReader, settings: sampleSmtp),
    'smtp_settings_empty_owner_360x800': (
      user: settingsOwner,
      settings: const SmtpSettings(
        host: '',
        port: 0,
        username: '',
        passwordSet: false,
        fromEmail: '',
        fromName: '',
        useTls: true,
        configured: false,
      ),
    ),
    'smtp_settings_no_access_360x800': (user: nonAdminWithSettingsPerm, settings: sampleSmtp),
  };

  for (final entry in cases.entries) {
    testWidgets(entry.key, (tester) async {
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = const Size(360, 800) * 2.0;
      addTearDown(tester.view.reset);
      await withRealShadows(() async {
        await tester.pumpWidget(
          smtpApp(user: entry.value.user, repo: FakeSettingsRepository(settings: entry.value.settings)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${entry.key}.png'));
      });
    });
  }
}
