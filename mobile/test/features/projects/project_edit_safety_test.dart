import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/widgets/access_notices.dart';

import '../../test_utils/fake_api_client.dart';
import 'project_edit_fakes.dart';

/// Proje düzenleme sayfasının yerleşimi (değiştirilemeyen bilgiler üstte,
/// Kaydet sonda), kayıt sürerken çıkışın engellenmesi ve proje detayında
/// boş "Hızlı İşlemler" başlığının gösterilmemesi.
Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(400, 2000) * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  late ApiClient offline;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    offline = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
  });

  testWidgets('değiştirilemeyen bilgiler formun ÜSTÜNDE, Kaydet sayfanın son öğesi', (tester) async {
    await _pump(tester, projectEditApp(user: projectOwner, repo: FakeProjectEditRepository(), offlineClient: offline));
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('Değiştirilemeyen Bilgiler'), lessThan(y('Proje Bilgileri')));
    expect(y('Açıklamalar'), lessThan(y('Değişiklikleri Kaydet')));
    expect(y('Proje No'), lessThan(y('Değişiklikleri Kaydet')));
  });

  testWidgets('kayıt sürerken sayfadan çıkılamaz; bitince detaya dönülür', (tester) async {
    final gate = Completer<void>();
    final repo = FakeProjectEditRepository()..saveGate = gate;
    await _pump(
      tester,
      projectEditApp(user: projectEditorNoFinance, repo: repo, offlineClient: offline, location: '/projeler/p1'),
    );
    await tester.tap(find.byTooltip('Düzenle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Değişiklikleri Kaydet'));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    expect(find.text('Projeyi Düzenle'), findsOneWidget);
    expect(find.text('Kaydediliyor, lütfen bitmesini bekle.'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(repo.updates, hasLength(1));
    expect(find.text('Projeyi Düzenle'), findsNothing);
  });

  testWidgets('yetkisiz: ortak "Yetkin yok" görünümü', (tester) async {
    await _pump(tester, projectEditApp(user: projectViewer, repo: FakeProjectEditRepository(), offlineClient: offline));
    expect(find.byType(NoAccessView), findsOneWidget);
  });

  group('proje detayı Hızlı İşlemler', () {
    testWidgets('hiçbir işlem yetkisi yoksa başlık da yok', (tester) async {
      await _pump(
        tester,
        projectEditApp(
          user: projectEditorNoFinance,
          repo: FakeProjectEditRepository(),
          offlineClient: offline,
          location: '/projeler/p1',
        ),
      );
      expect(find.text('Hızlı İşlemler'), findsNothing);
      expect(find.text('Proje Alanları'), findsOneWidget);
    });

    testWidgets('işlem varsa başlık ve kutucuklar', (tester) async {
      await _pump(
        tester,
        projectEditApp(user: projectOwner, repo: FakeProjectEditRepository(), offlineClient: offline, location: '/projeler/p1'),
      );
      expect(find.text('Hızlı İşlemler'), findsOneWidget);
      expect(find.text('Masraf Ekle'), findsOneWidget);
      expect(find.text('Görev Ekle'), findsOneWidget);
      // Finans görünümü olan kişi masraflarını Finans'ta görür.
      expect(find.text('Masraf Takibi'), findsNothing);
    });

    testWidgets('sahadaki kişi (finans izni yok): Masraf Ekle + Masraf Takibi, tahsilat yok (backend 0066)', (
      tester,
    ) async {
      final field = projectUser(permissions: const ['projects.read', 'projects.expenses.create']);
      await _pump(
        tester,
        projectEditApp(user: field, repo: FakeProjectEditRepository(), offlineClient: offline, location: '/projeler/p1'),
      );
      expect(find.text('Hızlı İşlemler'), findsOneWidget);
      expect(find.text('Masraf Ekle'), findsOneWidget);
      expect(find.text('Masraf Takibi'), findsOneWidget);
      expect(find.text('Tahsilat Ekle'), findsNothing);
      expect(find.text('Masraf & Tahsilat'), findsNothing, reason: 'Finans görünümü yine kapalı');
    });
  });
}
