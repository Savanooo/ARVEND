import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/core/update/update_controller.dart';
import 'package:arvend/core/update/update_presenter.dart';
import 'package:arvend/core/update/update_service.dart';
import 'package:arvend/features/profile/presentation/about_screen.dart';

import '../../test_utils/fake_api_client.dart';
import 'update_fakes.dart';

Map<String, dynamic> _meJson() => {
      'id': 'u1',
      'organization_id': 'org-1',
      'username': 'ahmet.yilmaz',
      'full_name': 'Ahmet Yılmaz',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': <String>[],
    };

void main() {
  late FakeHttpClientAdapter adapter;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'ArvenYapı',
      packageName: 'com.arvendyapi.arvend',
      version: '1.1.0',
      buildNumber: '2',
      buildSignature: '',
    );
  });

  Future<void> pumpAbout(
    WidgetTester tester, {
    required bool supported,
    List<ScriptedResponse> versionResponses = const [],
    FakeInstallService? service,
    DateTime Function()? clock,
  }) async {
    adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _meJson())],
      '/mobile/app-version': versionResponses,
    });
    final client = await buildFakeApiClient(adapter);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          updateSupportedProvider.overrideWithValue(supported),
          updateInstallServiceProvider.overrideWithValue(service ?? FakeInstallService()),
          if (clock != null) updateClockProvider.overrideWithValue(clock),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const AboutScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('iOS/web: "Güncellemeleri denetle" hiç gösterilmez', (tester) async {
    await pumpAbout(tester, supported: false);
    expect(find.text('Sürüm 1.1.0 (2)'), findsOneWidget);
    expect(find.text('Güncellemeleri denetle'), findsNothing);
  });

  testWidgets('güncelse "Güncel sürümü kullanıyorsun" mesajı', (tester) async {
    await pumpAbout(tester, supported: true, versionResponses: [
      (status: 200, body: {'platform': 'android', 'build': 0}),
    ]);
    expect(find.text('Güncellemeleri denetle'), findsOneWidget);

    await tester.tap(find.text('Güncellemeleri denetle'));
    await tester.pumpAndSettle();

    expect(find.text('$kUpdateUpToDateMessage · 1.1.0 (2)'), findsOneWidget);
    expect(find.text('Yeni sürüm hazır'), findsNothing);
    expect(adapter.calls.where((c) => c == '/mobile/app-version').length, 1);
  });

  testWidgets('yeni sürüm varsa istem açılır (erteleme dinlenmez)', (tester) async {
    // Kullanıcı bu build'i az önce "Sonra" ile ertelemiş olsa bile elle
    // denetim istemi gösterir.
    SharedPreferences.setMockInitialValues({
      'arvend.update.postponed_build': 3,
      'arvend.update.postponed_at': DateTime.now().millisecondsSinceEpoch,
    });
    await pumpAbout(tester, supported: true, versionResponses: [
      (status: 200, body: releaseJson(build: 3)),
    ]);

    await tester.tap(find.text('Güncellemeleri denetle'));
    await tester.pumpAndSettle();

    expect(find.text('Yeni sürüm hazır'), findsOneWidget);
    expect(find.text('Sonra'), findsOneWidget);
  });

  testWidgets('denetim başarısızsa bilgi mesajı (hata diyaloğu yok)', (tester) async {
    await pumpAbout(tester, supported: true, versionResponses: [
      (status: 500, body: {'error': 'sunucu hatası'}),
    ]);

    await tester.tap(find.text('Güncellemeleri denetle'));
    await tester.pumpAndSettle();

    expect(find.text(kUpdateCheckFailedMessage), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  int versionCalls() => adapter.calls.where((c) => c == '/mobile/app-version').length;

  testWidgets('istem açıkken yeni sürüm yayınlandı: indirme güncel sürümle kendiliğinden yapılır', (tester) async {
    // Kullanıcı build 3'ün istemini görürken sunucuya build 4 yayınlandı:
    // indirme ucu artık build 4'ü sunuyor (ETag farklı -> releaseChanged).
    final service = FakeInstallService(prepareErrors: [const UpdateFailure(UpdateFailureKind.releaseChanged)]);
    await pumpAbout(tester, supported: true, service: service, versionResponses: [
      (status: 200, body: releaseJson(build: 3)),
      (status: 200, body: releaseJson(build: 4, version: '1.3.0', sha256: 'b' * 64)),
    ]);

    await tester.tap(find.text('Güncellemeleri denetle'));
    await tester.pumpAndSettle();
    expect(find.text('Sürüm 1.2.0'), findsOneWidget);

    await tester.tap(find.text('Güncelle'));
    await tester.pumpAndSettle();

    expect(versionCalls(), 2, reason: 'sürüm bilgisi yeniden sorulmalı');
    expect(service.preparedBuilds, [3, 4]);
    expect(service.installCalls, 1);
    expect(find.textContaining('doğrulanamadı'), findsNothing);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('zorunlu istem tekrar açılırken bilgi eskiyse sunucuya yeniden sorulur', (tester) async {
    var now = DateTime(2026, 9, 28, 10);
    final service = FakeInstallService(prepareError: const UpdateFailure(UpdateFailureKind.network));
    await pumpAbout(tester, supported: true, service: service, clock: () => now, versionResponses: [
      (status: 200, body: releaseJson(build: 3, minBuild: 3)),
      // 7 saat sonra: geliştirici min_build'i düşürdü -- artık zorunlu değil.
      (status: 200, body: releaseJson(build: 3)),
    ]);

    await tester.tap(find.text('Güncellemeleri denetle'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);

    // Bilgi tazeyken: indirme başarısız -> "Kapat" -> zorunlu istem yeniden
    // açılır, yeni istek atılmaz.
    await tester.tap(find.text('Güncelle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kapat'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);
    expect(versionCalls(), 1);

    // Bilgi eskidiğinde: istem yeniden açılmadan önce sunucuya sorulur;
    // artık zorunlu değilse bir daha açılmaz.
    await tester.tap(find.text('Güncelle'));
    await tester.pumpAndSettle();
    now = now.add(const Duration(hours: 7));
    await tester.tap(find.text('Kapat'));
    await tester.pumpAndSettle();
    expect(versionCalls(), 2);
    expect(find.byType(Dialog), findsNothing);
  });
}
