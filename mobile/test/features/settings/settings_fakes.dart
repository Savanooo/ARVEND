import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/settings/data/settings_providers.dart';
import 'package:arvend/features/settings/data/settings_repository.dart';
import 'package:arvend/features/settings/domain/smtp_settings.dart';
import 'package:arvend/features/settings/settings_routes.dart';

import '../dashboard/fixtures.dart' show kAllPermissions;

class FakeSettingsRepository implements SettingsRepository {
  FakeSettingsRepository({SmtpSettings? settings}) : current = settings ?? sampleSmtp;

  SmtpSettings current;
  Object? loadError;
  Object? saveError;
  Object? testError;
  final calls = <String>[];
  final saved = <SmtpSettingsInput>[];
  final testRecipients = <String>[];

  @override
  Future<SmtpSettings> smtp() async {
    calls.add('get');
    if (loadError != null) throw loadError!;
    return current;
  }

  @override
  Future<SmtpSettings> updateSmtp(SmtpSettingsInput input) async {
    calls.add('put');
    if (saveError != null) throw saveError!;
    saved.add(input);
    current = SmtpSettings(
      host: input.host.trim(),
      port: input.port,
      username: input.username.trim(),
      passwordSet: current.passwordSet || input.password.isNotEmpty,
      fromEmail: input.fromEmail.trim(),
      fromName: input.fromName.trim(),
      useTls: input.useTls,
      configured: true,
    );
    return current;
  }

  @override
  Future<void> sendTestEmail(String to) async {
    calls.add('test');
    if (testError != null) throw testError!;
    testRecipients.add(to);
  }
}

const sampleSmtp = SmtpSettings(
  host: 'smtp.arvendyapi.com.tr',
  port: 587,
  username: 'teklif@arvendyapi.com.tr',
  passwordSet: true,
  fromEmail: 'teklif@arvendyapi.com.tr',
  fromName: 'Arvend Yapı',
  useTls: true,
  configured: true,
);

User settingsUser({required UserRole role, required Iterable<String> permissions}) => User(
      id: 'u1',
      organizationId: 'org-1',
      username: 'test',
      fullName: 'Test Kullanıcı',
      role: role,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      organizationName: 'Deneme Firma',
      permissions: permissions.toSet(),
    );

final settingsOwner = settingsUser(role: UserRole.admin, permissions: kAllPermissions);

/// Yönetici (kaba rol admin) ama yalnızca görüntüleme izni.
final settingsReader = settingsUser(role: UserRole.admin, permissions: const ['organization.settings.read']);

/// Kişiye özel izin verilmiş olsa bile kaba rolü admin olmayan üye: backend
/// requireAdmin ile reddeder, ekran da hiç açılmamalı.
final nonAdminWithSettingsPerm = settingsUser(
  role: UserRole.kullanici,
  permissions: const ['organization.settings.read', 'organization.settings.manage'],
);

class FakeAuthController extends AuthController {
  FakeAuthController(this._user);
  final User? _user;

  @override
  Future<User?> build() async => _user;
}

ThemeData goldenTheme() {
  final theme = AppTheme.light();
  final elevated = theme.elevatedButtonTheme.style;
  final buttonText = elevated?.textStyle?.resolve(const <WidgetState>{});
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: elevated?.copyWith(
        textStyle: WidgetStatePropertyAll((buttonText ?? const TextStyle()).copyWith(fontFamily: 'Inter')),
      ),
    ),
  );
}

Future<void> loadAppFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

Future<void> withRealShadows(Future<void> Function() body) async {
  debugDisableShadows = false;
  try {
    await body();
  } finally {
    debugDisableShadows = true;
  }
}

/// E-posta Ayarları, uygulamadaki gibi Diğer dalının ÜSTÜNE itilmiş hâliyle
/// (üst çubukta geri oku olur -- golden'lar gerçek görünümü yakalasın).
Widget smtpApp({required User? user, required FakeSettingsRepository repo}) {
  final router = GoRouter(
    initialLocation: '/diger/eposta-ayarlari',
    routes: [
      GoRoute(
        path: '/diger',
        builder: (_, _) => const Scaffold(body: Center(child: Text('Diğer'))),
        routes: settingsRoutes,
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuthController(user)),
      settingsRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: goldenTheme(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
    ),
  );
}
