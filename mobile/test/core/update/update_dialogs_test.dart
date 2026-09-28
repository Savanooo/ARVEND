import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/core/update/apk_installer.dart';
import 'package:arvend/core/update/app_release.dart';
import 'package:arvend/core/update/update_controller.dart';
import 'package:arvend/core/update/update_progress_dialog.dart';
import 'package:arvend/core/update/update_prompt_dialog.dart';
import 'package:arvend/core/update/update_service.dart';
import 'package:arvend/core/utils/formatters.dart';

import 'update_fakes.dart';

/// Diyaloğu gerçek `showDialog` ile açan küçük bir kabuk; dönen değer
/// [result]'a yazılır.
class _Harness<T> {
  T? result;
  bool closed = false;

  Widget build({required bool barrierDismissible, required WidgetBuilder dialog}) {
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showDialog<T>(
                  context: context,
                  barrierDismissible: barrierDismissible,
                  builder: dialog,
                );
                closed = true;
              },
              child: const Text('aç'),
            ),
          ),
        ),
      ),
    );
  }
}

final _release = AppRelease.fromJson(releaseJson(notes: 'Uzaktan güncelleme eklendi.'));
const _installed = InstalledVersion(version: '1.1.0', build: 2);

void main() {
  group('UpdatePromptDialog — normal', () {
    Future<_Harness<UpdatePromptChoice>> open(WidgetTester tester) async {
      final h = _Harness<UpdatePromptChoice>();
      await tester.pumpWidget(h.build(
        barrierDismissible: true,
        dialog: (_) => UpdatePromptDialog(release: _release, installed: _installed, mandatory: false),
      ));
      await tester.tap(find.text('aç'));
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('sürüm, boyut (MB), notlar ve iki buton gösterilir', (tester) async {
      await open(tester);
      expect(find.text('Yeni sürüm hazır'), findsOneWidget);
      expect(find.text('Sürüm 1.2.0'), findsOneWidget);
      expect(find.text('62,4${kNbsp}MB'), findsOneWidget);
      expect(find.text('Kurulu sürüm: 1.1.0 (2)'), findsOneWidget);
      expect(find.text('Uzaktan güncelleme eklendi.'), findsOneWidget);
      expect(find.text('Sonra'), findsOneWidget);
      expect(find.text('Güncelle'), findsOneWidget);
      expect(find.textContaining('zorunlu'), findsNothing);
    });

    testWidgets('"Sonra" -> later', (tester) async {
      final h = await open(tester);
      await tester.tap(find.text('Sonra'));
      await tester.pumpAndSettle();
      expect(h.result, UpdatePromptChoice.later);
      expect(find.text('Yeni sürüm hazır'), findsNothing);
    });

    testWidgets('"Güncelle" -> update', (tester) async {
      final h = await open(tester);
      await tester.tap(find.text('Güncelle'));
      await tester.pumpAndSettle();
      expect(h.result, UpdatePromptChoice.update);
    });

    testWidgets('geri tuşu kapatır ama erteleme sayılmaz (null)', (tester) async {
      final h = await open(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Yeni sürüm hazır'), findsNothing);
      expect(h.closed, isTrue);
      expect(h.result, isNull);
    });
  });

  group('UpdatePromptDialog — zorunlu', () {
    Future<_Harness<UpdatePromptChoice>> open(WidgetTester tester) async {
      final h = _Harness<UpdatePromptChoice>();
      await tester.pumpWidget(h.build(
        barrierDismissible: false,
        dialog: (_) => UpdatePromptDialog(release: _release, installed: _installed, mandatory: true),
      ));
      await tester.tap(find.text('aç'));
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('"Sonra" yok, güncellemenin zorunlu olduğu açıklanır', (tester) async {
      await open(tester);
      expect(find.text('Yeni sürüm hazır'), findsOneWidget);
      expect(find.text('Sonra'), findsNothing);
      expect(find.text('Güncelle'), findsOneWidget);
      expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);
    });

    testWidgets('geri tuşu ve dışarı dokunma diyaloğu KAPATMAZ', (tester) async {
      final h = await open(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Yeni sürüm hazır'), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Yeni sürüm hazır'), findsOneWidget);
      expect(h.closed, isFalse);

      await tester.tap(find.text('Güncelle'));
      await tester.pumpAndSettle();
      expect(h.result, UpdatePromptChoice.update);
    });
  });

  group('UpdateProgressDialog', () {
    Future<_Harness<UpdateFlowResult>> open(
      WidgetTester tester,
      FakeInstallService service, {
      Future<UpdateCheckResult> Function()? recheck,
    }) async {
      final h = _Harness<UpdateFlowResult>();
      await tester.pumpWidget(h.build(
        barrierDismissible: false,
        dialog: (_) => UpdateProgressDialog(release: _release, service: service, recheck: recheck),
      ));
      await tester.tap(find.text('aç'));
      await tester.pumpAndSettle();
      return h;
    }

    UpdateCheckResult available(AppRelease release) =>
        UpdateCheckResult(UpdateCheckStatus.available, release: release, installed: _installed);

    final newerRelease = AppRelease.fromJson(releaseJson(
      build: 4,
      version: '1.3.0',
      sha256: 'b' * 64,
      size: 63000000,
    ));

    group('kayıt eskimişse (istem açıkken yeni sürüm yayınlandı)', () {
      testWidgets('sunucu başka bir APK sunuyor: sürüm bilgisi yeniden sorulur, güncel sürüm kendiliğinden iner',
          (tester) async {
        final service = FakeInstallService(prepareErrors: [const UpdateFailure(UpdateFailureKind.releaseChanged)]);
        var rechecks = 0;
        final h = await open(tester, service, recheck: () async {
          rechecks++;
          return available(newerRelease);
        });

        expect(rechecks, 1);
        expect(service.preparedBuilds, [3, 4], reason: 'yeni kayıtla (build 4) baştan indirilmeli');
        expect(service.installCalls, 1);
        expect(h.result, UpdateFlowResult.installerOpened);
        expect(find.textContaining('doğrulanamadı'), findsNothing);
      });

      testWidgets('SHA tutmadı ve sunucu yeni sürüm yayınlamış: hata gösterilmeden yeni sürüm indirilir',
          (tester) async {
        final service = FakeInstallService(prepareErrors: [const UpdateFailure(UpdateFailureKind.checksumMismatch)]);
        final h = await open(tester, service, recheck: () async => available(newerRelease));

        expect(service.preparedBuilds, [3, 4]);
        expect(h.result, UpdateFlowResult.installerOpened);
      });

      testWidgets('SHA tutmadı ama kayıt AYNI: güvenlik hatası gösterilir, kurulum ekranı açılmaz', (tester) async {
        final service = FakeInstallService(prepareError: const UpdateFailure(UpdateFailureKind.checksumMismatch));
        var rechecks = 0;
        final h = await open(tester, service, recheck: () async {
          rechecks++;
          return available(_release);
        });

        expect(rechecks, 1);
        expect(service.preparedBuilds, [3]);
        expect(find.text('Güncelleme tamamlanamadı'), findsOneWidget);
        expect(find.textContaining('doğrulanamadı'), findsOneWidget);
        expect(service.installCalls, 0);
        expect(h.closed, isFalse);
      });

      testWidgets('yeniden sorulunca güncelleme artık yoksa (yayın geri çekildi) diyalog kapanır', (tester) async {
        final service = FakeInstallService(prepareErrors: [const UpdateFailure(UpdateFailureKind.releaseChanged)]);
        final h = await open(tester, service,
            recheck: () async => const UpdateCheckResult(UpdateCheckStatus.upToDate, installed: _installed));

        expect(h.result, UpdateFlowResult.noUpdate);
        expect(service.installCalls, 0);
      });

      testWidgets('sürüm bilgisi alınamazsa eldeki hata gösterilir; "Tekrar Dene" yeniden sorar', (tester) async {
        final service = FakeInstallService(prepareErrors: [const UpdateFailure(UpdateFailureKind.releaseChanged)]);
        var fail = true;
        final h = await open(tester, service, recheck: () async {
          if (fail) return const UpdateCheckResult(UpdateCheckStatus.failed);
          return available(newerRelease);
        });

        expect(find.text('Güncelleme tamamlanamadı'), findsOneWidget);
        expect(find.textContaining('daha yeni bir sürüm yayınlandı'), findsOneWidget);
        expect(service.installCalls, 0);

        fail = false;
        service.prepareErrors.add(const UpdateFailure(UpdateFailureKind.releaseChanged));
        await tester.tap(find.text('Tekrar Dene'));
        await tester.pumpAndSettle();
        expect(service.preparedBuilds, [3, 3, 4]);
        expect(h.result, UpdateFlowResult.installerOpened);
      });

      testWidgets('sunucu sürekli değişiyorsa kendiliğinden geçiş sınırlıdır (döngü yok)', (tester) async {
        final service = FakeInstallService(prepareError: const UpdateFailure(UpdateFailureKind.releaseChanged));
        var nextBuild = 4;
        await open(tester, service, recheck: () async {
          final build = nextBuild++;
          return available(AppRelease.fromJson(releaseJson(build: build, sha256: '$build'.padLeft(64, 'c'))));
        });

        expect(service.preparedBuilds, [3, 4, 5]);
        expect(find.text('Güncelleme tamamlanamadı'), findsOneWidget);
        expect(service.installCalls, 0);
      });
    });

    testWidgets('SHA uyuşmazlığı: hata gösterilir, kurulum ekranı açılmaz; "Tekrar Dene" yeniden indirir',
        (tester) async {
      final service = FakeInstallService(prepareError: const UpdateFailure(UpdateFailureKind.checksumMismatch));
      final h = await open(tester, service);

      expect(find.text('Güncelleme tamamlanamadı'), findsOneWidget);
      expect(find.textContaining('doğrulanamadı'), findsOneWidget);
      expect(service.installCalls, 0);
      expect(h.closed, isFalse);

      await tester.tap(find.text('Tekrar Dene'));
      await tester.pumpAndSettle();
      expect(service.prepareCalls, 2);
      expect(service.installCalls, 0);

      await tester.tap(find.text('Kapat'));
      await tester.pumpAndSettle();
      expect(h.result, UpdateFlowResult.cancelled);
    });

    testWidgets('indirme yüzdesi gösterilir; "İptal" indirmeyi iptal edip kapatır', (tester) async {
      final service = FakeInstallService(holdDownload: true);
      final h = await open(tester, service);

      expect(find.text('Güncelleme indiriliyor'), findsOneWidget);
      expect(find.text('%50'), findsOneWidget);
      expect(find.text('31,2 / 62,4${kNbsp}MB'), findsOneWidget);

      // Geri tuşu indirmeyi yarıda bırakmaz.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Güncelleme indiriliyor'), findsOneWidget);

      await tester.tap(find.text('İptal'));
      await tester.pumpAndSettle();
      expect(service.lastToken!.isCancelled, isTrue);
      expect(h.result, UpdateFlowResult.cancelled);
      expect(service.installCalls, 0);
    });

    testWidgets('kurulum izni yoksa Türkçe rehber + "Ayarları Aç" + "Tekrar Dene"', (tester) async {
      final service = FakeInstallService(
        installResults: [ApkInstallResult.permissionRequired, ApkInstallResult.opened],
      );
      final h = await open(tester, service);

      expect(find.text('Kurulum izni gerekli'), findsOneWidget);
      // Android'in Türkçe ayar sayfasındaki anahtarın birebir adı.
      expect(find.text('Ayarlar → Bu kaynaktan izin ver'), findsOneWidget);
      expect(find.text('"Bu kaynaktan izin ver" seçeneğini aç.'), findsOneWidget);
      expect(find.textContaining('yüklemeye izin ver'), findsNothing);

      await tester.tap(find.text('Ayarları Aç'));
      await tester.pumpAndSettle();
      expect(service.settingsOpened, 1);

      await tester.tap(find.text('Tekrar Dene'));
      await tester.pumpAndSettle();
      expect(service.installCalls, 2);
      expect(service.prepareCalls, 1, reason: 'doğrulanmış dosya yeniden indirilmez');
      expect(h.result, UpdateFlowResult.installerOpened);
    });

    testWidgets('doğrulama geçerse kurulum ekranı açılır ve diyalog kapanır', (tester) async {
      final service = FakeInstallService();
      final h = await open(tester, service);
      expect(service.installCalls, 1);
      expect(h.result, UpdateFlowResult.installerOpened);
    });

    testWidgets('401 -> loginRequired ile kapanır', (tester) async {
      final service = FakeInstallService(prepareError: const UpdateFailure(UpdateFailureKind.loginRequired));
      final h = await open(tester, service);
      expect(h.result, UpdateFlowResult.loginRequired);
      expect(service.installCalls, 0);
    });
  });
}
