import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/utils/formatters.dart';
import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/contract_co/contract_co_routes.dart';
import 'package:arvend/features/projects/contract_co/domain/project_change_order.dart';
import 'package:arvend/features/projects/contract_co/presentation/widgets/contract_co_ui.dart';

import 'contract_co_test_support.dart';

/// Ek İşler: liste -> detay -> form -> yaşam döngüsü (Gönder/Mail/Link/
/// Revize/İptal), izin kapıları (finance.read/manage), 403/409 davranışı,
/// proje kapalıyken aksiyon yok, düzenlemede gizli alanların korunması.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  Future<FakeContractCoRepository> pump(
    WidgetTester tester, {
    required User user,
    FakeContractCoRepository? repo,
    String location = '/projeler/p1/ek-isler',
    String projectStatus = 'active',
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 2400);
    addTearDown(tester.view.reset);
    final r = repo ?? FakeContractCoRepository();
    await tester.pumpWidget(buildContractCoApp(
      user: user,
      repo: r,
      initialLocation: location,
      project: sampleProject(status: projectStatus),
    ));
    await tester.pumpAndSettle();
    return r;
  }

  Future<void> confirmDialog(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, label)));
    await tester.pumpAndSettle();
  }

  group('liste', () {
    testWidgets('sahip: değer özeti, "Ek İş Oluştur" ve satırlar', (tester) async {
      await pump(tester, user: ownerUser);
      expect(find.text('Güncel Proje Bedeli'), findsOneWidget);
      expect(find.text('1.346.000,00 TL'), findsOneWidget);
      expect(find.textContaining('Onay bekleyen ek iş: −30.000,00 TL'), findsOneWidget);
      expect(find.text('Ek İş Oluştur'), findsOneWidget);
      expect(find.text('Mutfak dolabı ilavesi'), findsOneWidget);
      expect(find.text('+96.000,00 TL'), findsWidgets);
      // Eksiltme işaretli ve eksi ile.
      expect(find.text('−30.000,00 TL'), findsOneWidget);
      expect(find.byType(ReadOnlyNotice), findsNothing);
    });

    testWidgets('salt-okunur: oluşturma yok, bilgilendirme var', (tester) async {
      await pump(tester, user: readOnlyUser);
      expect(find.text('Ek İş Oluştur'), findsNothing);
      expect(find.text(kChangeOrdersReadOnlyText), findsOneWidget);
      expect(find.text('Seramik kaplama iptali (arşiv odası)'), findsOneWidget);
    });

    testWidgets('finans izni yok: API çağrılmadan "yetkin yok" (tutar yok)', (tester) async {
      final repo = await pump(tester, user: pmUser);
      expect(find.text(kChangeOrdersNoAccessText), findsOneWidget);
      expect(find.textContaining('TL'), findsNothing);
      expect(repo.calls, isEmpty);
    });

    testWidgets('sunucu 403: çökmez', (tester) async {
      final repo = FakeContractCoRepository()..listError = forbidden;
      await pump(tester, user: ownerUser, repo: repo);
      expect(tester.takeException(), isNull);
      expect(find.text(kChangeOrdersNoAccessText), findsOneWidget);
    });

    testWidgets('boş liste', (tester) async {
      await pump(tester, user: ownerUser, repo: FakeContractCoRepository(changeOrders: []));
      expect(find.text('Henüz ek iş/değişiklik emri yok.'), findsOneWidget);
    });

    testWidgets('proje kapalı: oluşturma yok, kilit notu', (tester) async {
      await pump(tester, user: ownerUser, projectStatus: 'cancelled');
      expect(find.text('Ek İş Oluştur'), findsNothing);
      expect(find.text(kProjectLockedText), findsOneWidget);
    });

    testWidgets('satır detayı açar', (tester) async {
      await pump(tester, user: ownerUser);
      await tester.tap(find.text('Seramik kaplama iptali (arşiv odası)'));
      await tester.pumpAndSettle();
      expect(find.text('Müşteri yanıtı bekleniyor'), findsOneWidget);
    });
  });

  group('detay', () {
    testWidgets('taslak: kalemler, toplamlar, notlar, kârlılık; Gönder/Düzenle/İptal', (tester) async {
      await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co3'));
      expect(find.text('EK-003'), findsOneWidget);
      expect(find.text('Ek priz hattı (toplantı odası)'), findsOneWidget);
      expect(find.text('36,5 m × 120,00 TL'), findsOneWidget);
      expect(find.text('17.496,00 TL'), findsOneWidget);
      expect(find.text('KDV (%20)'), findsOneWidget);
      expect(find.text('Çalışma hafta sonu yapılacaktır.'), findsOneWidget);
      expect(find.text('Kârlılık (dahili)'), findsOneWidget);
      expect(find.text('Önceki revizyon: EK-002'), findsOneWidget);
      expect(find.text('Gönder'), findsOneWidget);
      expect(find.text('Düzenle'), findsOneWidget);
      expect(find.text('İptal Et'), findsOneWidget);
      expect(find.text('Mail Gönder'), findsNothing);
      expect(find.text('Revize Et'), findsNothing);
      // Revizyon olayı yeni kayıtta böyle okunur.
      expect(find.text('Revizyon olarak oluşturuldu'), findsOneWidget);
    });

    testWidgets('paylaşım linki metni yalnızca "Linki Kopyala"yı görebilene (finans yönetimi)', (tester) async {
      // Link müşteri adına onay/red verdirir: salt-okur finans kullanıcısı
      // kopyalama düğmesini görmüyorsa metni de görmemeli.
      await pump(tester, user: readOnlyUser, location: projectChangeOrderPath('p1', 'co4'));
      expect(find.text('Müşteri yanıtı bekleniyor'), findsOneWidget);
      expect(find.text('Linki Kopyala'), findsNothing);
      expect(find.textContaining('/ek-is/'), findsNothing);
      expect(find.text('Müşteri paylaşım linki aktif.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co4'));
      expect(find.text('Linki Kopyala'), findsOneWidget);
      expect(find.textContaining('/ek-is/6f1c2d3e-aaaa-bbbb-cccc-1234567890ab'), findsOneWidget);
    });

    testWidgets('olay geçmişi en yeni üstte', (tester) async {
      await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co4'));
      await tester.scrollUntilVisible(find.text('Ek iş oluşturuldu'), 300, scrollable: find.byType(Scrollable).last);
      final sent = tester.getTopLeft(find.text('Ek iş müşteriye gönderildi'));
      final created = tester.getTopLeft(find.text('Ek iş oluşturuldu'));
      expect(sent.dy, lessThan(created.dy));
    });

    testWidgets('Gönder: onay -> gönderildi, link aksiyonları gelir', (tester) async {
      final repo = await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co3'));
      await tester.tap(find.text('Gönder'));
      await tester.pumpAndSettle();
      expect(find.text('Ek İşi Gönder'), findsOneWidget);
      await confirmDialog(tester, 'Gönder');
      expect(repo.calls, contains('sendChangeOrder:co3'));
      expect(find.text('EK-003 müşteriye gönderildi.'), findsOneWidget);
      expect(find.text('Müşteri yanıtı bekleniyor'), findsOneWidget);
      expect(find.text('Mail Gönder'), findsOneWidget);
      expect(find.text('Linki Kopyala'), findsOneWidget);
      expect(find.text('Revize Et'), findsOneWidget);
      expect(find.text('Düzenle'), findsNothing);
    });

    testWidgets('gönderildi: Linki Kopyala panoya paylaşım adresini yazar', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co4'));
      expect(find.text('https://app.arvendyapi.com.tr/ek-is/6f1c2d3e-aaaa-bbbb-cccc-1234567890ab'), findsOneWidget);
      await tester.tap(find.text('Linki Kopyala'));
      await tester.pumpAndSettle();
      expect(copied, changeOrderShareUrl('6f1c2d3e-aaaa-bbbb-cccc-1234567890ab'));
      expect(find.text('Link kopyalandı.'), findsOneWidget);
    });

    testWidgets('Mail Gönder: alıcı müşteri e-postasıyla dolu, gönderilir', (tester) async {
      final repo = await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co4'));
      await tester.tap(find.text('Mail Gönder'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'satinalma@modamimarlik.com'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, 'Konu (opsiyonel)'), 'Onayınıza sunulmuştur');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Gönder'));
      await tester.pumpAndSettle();
      expect(repo.emails, hasLength(1));
      expect(repo.emails.single.to, 'satinalma@modamimarlik.com');
      expect(repo.emails.single.subject, 'Onayınıza sunulmuştur');
      expect(find.text('Mail gönderildi.'), findsOneWidget);
    });

    testWidgets('Mail Gönder: alıcı boşsa gönderilmez', (tester) async {
      final repo = await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co4'));
      await tester.tap(find.text('Mail Gönder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'satinalma@modamimarlik.com'), '');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Gönder'));
      await tester.pumpAndSettle();
      expect(find.text('Alıcı e-posta adresi zorunludur'), findsOneWidget);
      expect(repo.emails, isEmpty);
    });

    testWidgets('SMTP hatası sayfada gösterilir, sayfa açık kalır', (tester) async {
      final repo = FakeContractCoRepository();
      await pump(tester, user: ownerUser, repo: repo, location: projectChangeOrderPath('p1', 'co4'));
      repo.writeError = const ApiException(
        statusCode: 400,
        message: 'e-posta gönderilemedi: bağlantı reddedildi',
        kind: ApiErrorKind.badRequest,
      );
      await tester.tap(find.text('Mail Gönder'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Gönder'));
      await tester.pumpAndSettle();
      expect(find.text('e-posta gönderilemedi: bağlantı reddedildi'), findsOneWidget);
      expect(find.text('Mail gönderildi.'), findsNothing);
      expect(find.text('Kime'), findsOneWidget);
    });

    testWidgets('Revize Et: yeni taslağa geçer', (tester) async {
      final repo = await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co5'));
      expect(find.text('Müşteri reddetti'), findsOneWidget);
      expect(find.text('İptal Et'), findsNothing);
      await tester.tap(find.text('Revize Et'));
      await tester.pumpAndSettle();
      await confirmDialog(tester, 'Revize Et');
      expect(repo.calls, contains('reviseChangeOrder:co5'));
      expect(find.text('Yeni revizyon (taslak) oluşturuldu.'), findsOneWidget);
      expect(find.text('EK-006'), findsOneWidget);
      expect(find.text('Önceki revizyon: EK-005'), findsOneWidget);
      expect(find.text('Gönder'), findsOneWidget);
    });

    testWidgets('İptal Et: onay -> iptal', (tester) async {
      final repo = await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co4'));
      await tester.tap(find.text('İptal Et'));
      await tester.pumpAndSettle();
      expect(find.text('Bu ek işi iptal etmek istediğine emin misin? Paylaşım linki de geçersiz olur.'), findsOneWidget);
      await confirmDialog(tester, 'İptal Et');
      expect(repo.calls, contains('cancelChangeOrder:co4'));
      expect(find.text('İptal edildi'), findsOneWidget);
      expect(find.text('Mail Gönder'), findsNothing);
    });

    testWidgets('409 (müşteri bu arada onayladı): mesaj + güncel durum', (tester) async {
      final repo = FakeContractCoRepository();
      await pump(tester, user: ownerUser, repo: repo, location: projectChangeOrderPath('p1', 'co4'));
      repo.writeError = conflict('bu ek iş iptal edilemez');
      final i = repo.store.indexWhere((c) => c.id == 'co4');
      repo.store[i] = ProjectChangeOrder.fromJson({
        'id': 'co4',
        'change_order_no': 'EK-004',
        'change_type': 'deduction',
        'title': 'Seramik kaplama iptali (arşiv odası)',
        'status': 'approved',
        'grand_total': 30000,
        'approved_at': '2026-09-20T09:00:00Z',
      });
      await tester.tap(find.text('İptal Et'));
      await tester.pumpAndSettle();
      await confirmDialog(tester, 'İptal Et');
      expect(find.text('bu ek iş iptal edilemez'), findsOneWidget);
      expect(find.text('Müşteri onayladı'), findsOneWidget);
      expect(find.text('İptal Et'), findsNothing);
    });

    testWidgets('onaylandı: aksiyon yok (final)', (tester) async {
      await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co1'));
      expect(find.text('Müşteri onayladı'), findsOneWidget);
      for (final label in ['Gönder', 'Düzenle', 'İptal Et', 'Revize Et', 'Mail Gönder', 'Linki Kopyala']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      expect(find.byType(ReadOnlyNotice), findsNothing);
    });

    testWidgets('yenilendi: yeni revizyona bağlantı', (tester) async {
      await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co2'));
      expect(find.text('Yerine yeni revizyon oluşturuldu'), findsOneWidget);
      await tester.tap(find.text('EK-003 revizyonunu aç'));
      await tester.pumpAndSettle();
      expect(find.text('EK-003'), findsOneWidget);
    });

    testWidgets('salt-okunur: aksiyon yok, bilgilendirme var', (tester) async {
      await pump(tester, user: readOnlyUser, location: projectChangeOrderPath('p1', 'co4'));
      for (final label in ['Mail Gönder', 'Linki Kopyala', 'Revize Et', 'İptal Et']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      expect(find.text(kChangeOrdersReadOnlyText), findsOneWidget);
    });

    testWidgets('proje kapalı: aksiyon yok, kilit notu', (tester) async {
      await pump(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co3'), projectStatus: 'completed');
      expect(find.text('Gönder'), findsNothing);
      expect(find.text(kProjectLockedText), findsOneWidget);
    });

    testWidgets('finans izni yok: API çağrılmadan "yetkin yok"', (tester) async {
      final repo = await pump(tester, user: fieldUser, location: projectChangeOrderPath('p1', 'co3'));
      expect(find.text(kChangeOrdersNoAccessText), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('detay 403: çökmez', (tester) async {
      final repo = FakeContractCoRepository()..detailError = forbidden;
      await pump(tester, user: ownerUser, repo: repo, location: projectChangeOrderPath('p1', 'co3'));
      expect(tester.takeException(), isNull);
      expect(find.text(kChangeOrdersNoAccessText), findsOneWidget);
    });
  });

  group('form', () {
    testWidgets('oluştur: doğrulama, gönderim ve detaya geçiş', (tester) async {
      final repo = await pump(tester, user: ownerUser, location: projectChangeOrderNewPath('p1'));
      expect(find.text('Yeni Ek İş'), findsOneWidget);
      // Başlık yok + kalem yok.
      await tester.tap(find.text('Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('Ek iş başlığı zorunludur'), findsOneWidget);
      expect(find.text('En az bir kalem girilmeli ve toplam sıfırdan büyük olmalıdır.'), findsNothing);

      await tester.enterText(find.widgetWithText(TextFormField, 'Başlık *'), 'Ek aydınlatma');
      await tester.tap(find.text('Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('En az bir kalem girilmeli ve toplam sıfırdan büyük olmalıdır.'), findsOneWidget);
      expect(repo.created, isEmpty);

      // Açıklama var, fiyat yok -> satır doğrulaması.
      await tester.enterText(find.widgetWithText(TextFormField, 'Kalem açıklaması *'), 'LED panel');
      await tester.tap(find.text('Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('Birim fiyat sıfırdan büyük olmalı'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, 'Birim Fiyat (TRY) *'), '1.250,50');
      await tester.enterText(find.widgetWithText(TextFormField, 'Miktar *'), '4');
      await tester.tap(find.text('Ek İş'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eksiltme').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oluştur'));
      await tester.pumpAndSettle();

      expect(repo.created, hasLength(1));
      final input = repo.created.single;
      expect(input.title, 'Ek aydınlatma');
      expect(input.changeType, ProjectChangeOrder.typeDeduction);
      expect(input.vatRate, 20);
      expect(input.items.single.description, 'LED panel');
      expect(input.items.single.quantity, 4);
      expect(input.items.single.unit, 'adet');
      expect(input.items.single.unitPrice, 1250.5);
      // Detaya geçildi.
      expect(find.text('EK-006 oluşturuldu.'), findsOneWidget);
      expect(find.text('EK-006'), findsOneWidget);
    });

    testWidgets('düzenle: mevcut değerler dolu; gizli kalem alanları korunur', (tester) async {
      final repo = await pump(tester, user: ownerUser, location: projectChangeOrderEditPath('p1', 'co3'));
      expect(find.text('Ek İşi Düzenle'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Toplantı odası elektrik ilavesi'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '36,5'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, 'Toplantı odası elektrik ilavesi'), 'Elektrik ilavesi (rev.)');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.updated, hasLength(1));
      final (id, input) = repo.updated.single;
      expect(id, 'co3');
      expect(input.title, 'Elektrik ilavesi (rev.)');
      expect(input.items, hasLength(2));
      expect(input.items.first.productId, 'prod-9');
      expect(input.items.first.estimatedUnitCost, 520);
      expect(input.items.first.toJson()['estimated_unit_cost'], 520);
      expect(input.items.last.quantity, 36.5);
      expect(input.customerNotes, 'Çalışma hafta sonu yapılacaktır.');
      expect(input.internalNotes, 'Malzeme depoda mevcut.');
      expect(input.description, 'Müşterinin istediği ek priz hattı ve kablo kanalı.');
      // Detaya dönüldü.
      expect(find.text('EK-003 kaydedildi.'), findsOneWidget);
    });

    testWidgets('kalem ekle/sil', (tester) async {
      await pump(tester, user: ownerUser, location: projectChangeOrderNewPath('p1'));
      expect(find.byTooltip('Kalemi Sil'), findsNothing);
      await tester.tap(find.text('Kalem Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Kalem 2'), findsOneWidget);
      expect(find.byTooltip('Kalemi Sil'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Kalemi Sil').first);
      await tester.pumpAndSettle();
      expect(find.text('Kalem 2'), findsNothing);
    });

    testWidgets('gönderilmiş ek iş düzenlenemez', (tester) async {
      await pump(tester, user: ownerUser, location: projectChangeOrderEditPath('p1', 'co4'));
      expect(find.text('Yalnızca taslak durumundaki ek işler düzenlenebilir.'), findsOneWidget);
      expect(find.text('Kaydet'), findsNothing);
    });

    testWidgets('yazma izni yok: form açılmaz', (tester) async {
      final repo = await pump(tester, user: readOnlyUser, location: projectChangeOrderNewPath('p1'));
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('Türkçe binlik: "8.500" sekiz bin beş yüz kaydedilir; satır ve toplam önizlemesi görünür', (tester) async {
      // Regresyon: eski ayrıştırıcı "8.500"ü 8,50 TL kaydediyordu (müşteriye
      // 1000 kat küçük ek iş gidiyordu) ve form hiç toplam göstermiyordu.
      final repo = await pump(tester, user: ownerUser, location: projectChangeOrderNewPath('p1'));
      await tester.enterText(find.widgetWithText(TextFormField, 'Başlık *'), 'Ek priz hattı');
      await tester.enterText(find.widgetWithText(TextFormField, 'Kalem açıklaması *'), 'Ek priz hattı');
      await tester.enterText(find.widgetWithText(TextFormField, 'Miktar *'), '12');
      await tester.enterText(find.widgetWithText(TextFormField, 'Birim Fiyat (TRY) *'), '8.500');
      await tester.pump();
      expect(find.text('Satır toplamı: ${Formatters.money(102000)}'), findsOneWidget);
      final preview = find.byKey(const ValueKey('change-order-totals-preview'));
      expect(find.descendant(of: preview, matching: find.text(Formatters.money(102000))), findsOneWidget);
      expect(find.descendant(of: preview, matching: find.text(Formatters.money(20400))), findsOneWidget);
      expect(find.descendant(of: preview, matching: find.text(Formatters.money(122400))), findsOneWidget);

      await tester.tap(find.text('Oluştur'));
      await tester.pumpAndSettle();
      expect(repo.created.single.items.single.unitPrice, 8500);
      expect(repo.created.single.items.single.quantity, 12);
    });

    testWidgets('geçersiz sayı ve %100 üstü KDV reddedilir', (tester) async {
      final repo = await pump(tester, user: ownerUser, location: projectChangeOrderNewPath('p1'));
      await tester.enterText(find.widgetWithText(TextFormField, 'Başlık *'), 'Deneme');
      await tester.enterText(find.widgetWithText(TextFormField, 'Kalem açıklaması *'), 'Kalem');
      await tester.enterText(find.widgetWithText(TextFormField, 'Birim Fiyat (TRY) *'), 'NaN');
      await tester.enterText(find.widgetWithText(TextFormField, 'KDV (%) *'), '120');
      await tester.tap(find.text('Oluştur'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Geçerli bir sayı gir'), findsOneWidget);
      expect(find.text('KDV oranı en fazla %100 olabilir'), findsOneWidget);
      expect(repo.created, isEmpty);
    });

    testWidgets('kaydedilmemiş değişiklikle geri: onay sorulur', (tester) async {
      await pump(tester, user: ownerUser, location: '/projeler/p1/ek-isler');
      await tester.tap(find.text('Ek İş Oluştur'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Başlık *'), 'Yarım kalan');
      await tester.pump();
      // Sistem geri hareketi (Android geri tuşu).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Kaydedilmemiş değişiklikler'), findsOneWidget);
    });
  });

  group('proje detayına gömülü (bölüm tanımları)', () {
    for (final entry in contractCoSections) {
      testWidgets('${entry.label}: Expanded içinde çizilir, satır detay açar', (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(400, 900);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(buildContractCoApp(
          user: ownerUser,
          repo: FakeContractCoRepository(),
          initialLocation: '/projeler/p1',
          projectPage: (id) => embeddedSectionPage(entry.builder(id, sampleProject()), selected: entry.alt),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final row = find.text('Seramik kaplama iptali (arşiv odası)');
        // İlk kaydırıcı yatay çip şeridi; gövde dikey olan.
        final body = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
        await tester.scrollUntilVisible(row, 200, scrollable: body);
        await tester.drag(body, const Offset(0, -200));
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text('Müşteri yanıtı bekleniyor'), findsOneWidget);
        // Geri: gömülü sekmeye dönülür.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('proje-alt-${entry.alt}')), findsOneWidget);
      });
    }
  });
}
