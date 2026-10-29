import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/files/device_picker.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/project_photo_cache.dart';
import 'package:arvend/features/projects/domain/expense_actions.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/expense_attachments/data/expense_attachments_repository.dart';
import 'package:arvend/features/projects/finance_ledger/presentation/ledger_entry_sheet.dart';
import 'package:arvend/features/projects/my_expenses/presentation/expenses_screen.dart';
import 'package:arvend/features/projects/my_expenses/presentation/my_expenses_screen.dart';
import 'package:arvend/features/projects/presentation/expense_form_sheet.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import 'my_expenses_test_support.dart';

/// Kullanıcı geri bildirimleri (backend migration 0076):
///   - "Genel giren masraflar hiç gözükmüyor": sahadaki kişi girdiği genel
///     masrafı Masraflarım'da görür; finans okuması olmayan onaylayıcı onay
///     bekleyen genel masrafı Masraflar'da görür ve karar verir.
///   - "Masraf girme yerine resim ve dosya ekleme gibi bir yer olsun": formda
///     fiş/belge ekle-kaldır, kayıttan sonra yükleme, yüklenemeyeni
///     ayrıntıdan tekrar deneme; onaylayıcı karar vermeden fişi görür.

/// Onaylayıcı (kişiye özel onay izni), finans okuması yok.
final _approver = cc.buildUser(
  id: 'appr',
  roleCode: 'field',
  permissions: const {'projects.read', 'projects.expenses.create', 'projects.expenses.approve'},
);

Map<String, dynamic> _attachment(
  String id, {
  String expense = 'g1',
  String mime = 'image/png',
  String name = 'fis.png',
}) => {
  'id': id,
  'expense_id': expense,
  'original_name': name,
  'mime_type': mime,
  'size_bytes': 2048,
  'sha256': 'x' * 64,
  'uploaded_by': 'field',
  'created_at': '2026-10-28T09:00:00Z',
};

Map<String, dynamic> _generalRow(
  String id, {
  String status = 'pending',
  String createdBy = 'field',
  List<Map<String, dynamic>>? attachments,
}) => {
  ...myExpenseRow(id, status: status, createdBy: createdBy, description: 'Yakıt'),
  'project_id': '',
  'project_name': '',
  'project_no': '',
  'project_status': '',
  'is_general': true,
  'created_by_name': 'Saha Çalışanı',
  'attachments': attachments ?? const [],
};

class _FakePicker implements DevicePicker {
  _FakePicker({this.images = const [], this.files = const []});
  final List<PickedDeviceFile> images;
  final List<PickedDeviceFile> files;
  int _image = 0;
  int _file = 0;

  @override
  Future<PickedDeviceFile?> pickImage(ImageSource source) async => _image < images.length ? images[_image++] : null;

  @override
  Future<PickedDeviceFile?> pickFile() async => _file < files.length ? files[_file++] : null;
}

/// Yüklemeyi dosya okumadan kaydeden depo; [failNames] adlı dosyalar bir
/// kez düşer (ağ kesildi).
class _FakeAttachmentsRepo implements ExpenseAttachmentsRepository {
  _FakeAttachmentsRepo({Set<String> failNames = const {}}) : _failOnce = {...failNames};
  final Set<String> _failOnce;
  final uploads = <({String projectId, String expenseId, String name})>[];
  final deletes = <String>[];

  @override
  Future<ExpenseAttachment> upload(
    String projectId,
    String expenseId, {
    required String filePath,
    required String fileName,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    onSendProgress?.call(50, 100);
    if (_failOnce.remove(fileName)) {
      throw const ApiException(statusCode: null, message: 'Sunucuya ulaşılamadı.', kind: ApiErrorKind.network);
    }
    uploads.add((projectId: projectId, expenseId: expenseId, name: fileName));
    onSendProgress?.call(100, 100);
    return ExpenseAttachment.fromJson(
      _attachment('up${uploads.length}', expense: expenseId, name: fileName, mime: 'image/jpeg'),
    );
  }

  @override
  Future<void> delete(String projectId, String expenseId, String attachmentId) async => deletes.add(attachmentId);

  @override
  Future<List<ExpenseAttachment>> list(String projectId, String expenseId) async => const [];

  @override
  Future<Uint8List> bytes(String projectId, String expenseId, String attachmentId) async => Uint8List(8);
}

Widget _app({required Widget home}) => MaterialApp(
  theme: AppTheme.light(),
  locale: const Locale('tr', 'TR'),
  supportedLocales: const [Locale('tr', 'TR')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: home,
);

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required User user,
  required Widget home,
  Map<String, List<ScriptedResponse>> script = const {},
  List<Override> overrides = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
        expenseAttachmentCacheProvider.overrideWithValue(ProjectPhotoCache(directory: () async => null)),
        ...overrides,
      ],
      child: _app(home: home),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  group('genel masraf görünürlüğü', () {
    testWidgets('saha çalışanı girdiği genel masrafı Masraflarım\'da "Genel masraf" olarak görür ve geri çeker', (
      tester,
    ) async {
      final adapter = await _pump(
        tester,
        user: myExpensesFieldUser,
        home: const MyExpensesScreen(),
        script: {
          '/expenses/mine': [
            mineResponse([_generalRow('g1'), myExpenseRow('m1', description: 'Çivi')]),
            mineResponse([_generalRow('g1')]),
          ],
          '/expenses/general/g1/void': [(status: 200, body: _generalRow('g1'))],
        },
      );
      expect(find.textContaining('Genel masraf · '), findsOneWidget);
      expect(find.textContaining('PRJ-2026-0007'), findsOneWidget);

      await _tapVisible(tester, find.byKey(const ValueKey('masrafim-g1')));
      expect(find.text('Genel masraf'), findsOneWidget, reason: 'ayrıntıda proje yerine "Genel masraf"');
      expect(find.text('Fiş veya belge eklenmemiş.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('masraf-belge-ekle')),
        findsOneWidget,
        reason: 'kendi bekleyen masrafına belge ekler',
      );
      await _tapVisible(tester, find.byKey(const ValueKey('masraf-geri-cek')));
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Geri Çek')));
      await tester.pumpAndSettle();
      expect(adapter.calls, contains('/expenses/general/g1/void'), reason: 'genel masraf genel uçtan geri çekilir');
    });

    testWidgets('finans okuması olmayan onaylayıcı bekleyen genel masrafı görür, fişi açar ve onaylar', (tester) async {
      final adapter = await _pump(
        tester,
        user: _approver,
        home: const ExpensesScreen(initialStatus: 'pending'),
        script: {
          '/expenses': [
            (
              status: 200,
              body: {
                'expenses': [
                  _generalRow(
                    'g1',
                    attachments: [
                      _attachment('a1'),
                      _attachment('a2', mime: 'application/pdf', name: 'fatura.pdf'),
                    ],
                  ),
                ],
                'limit': 500,
                'truncated': false,
                'can_see_all': false,
                'scope': 'approver',
                'approver_recent_days': 30,
              },
            ),
            (
              status: 200,
              body: {'expenses': [], 'limit': 500, 'truncated': false, 'can_see_all': false, 'scope': 'approver'},
            ),
          ],
          '/expenses/general/g1/attachments/a1/content': [(status: 200, body: List<int>.filled(16, 1))],
          '/expenses/general/g1/approve': [(status: 200, body: _generalRow('g1', status: 'approved'))],
        },
      );
      expect(adapter.requestQueries.first, {'status': 'pending'}, reason: 'bildirimden onay bekleyenlerle açılır');
      expect(find.byKey(const ValueKey('masraf-toplamlar')), findsNothing, reason: 'onaylayıcıya toplam yok');
      expect(find.textContaining('Saha Çalışanı'), findsOneWidget, reason: 'kimin girdiğini görür');
      expect(find.textContaining('Onay bekleyen masraflar, son 30 günde'), findsOneWidget);
      expect(find.byIcon(Icons.attach_file), findsOneWidget, reason: 'kartta belge sayısı');

      await _tapVisible(tester, find.byKey(const ValueKey('masraf-g1')));
      expect(find.text('Fiş / Belge (2)'), findsOneWidget);
      expect(find.byKey(const ValueKey('masraf-belge-a1')), findsOneWidget);
      expect(find.byKey(const ValueKey('masraf-belge-a2')), findsOneWidget);
      expect(
        adapter.calls,
        contains('/expenses/general/g1/attachments/a1/content'),
        reason: 'küçük resim çerezli istemciden',
      );
      expect(
        find.byKey(const ValueKey('masraf-belge-ekle')),
        findsNothing,
        reason: 'başkasının masrafına belge eklemez',
      );
      expect(find.byKey(const ValueKey('masraf-belge-kaldir-a1')), findsNothing);

      // Fişe dokununca tam ekran.
      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-a1')));
      expect(find.byKey(const ValueKey('masraf-belge-tam-ekran')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const ValueKey('masraf-belge-tam-ekran')))).pop();
      await tester.pumpAndSettle();

      await _tapVisible(tester, find.widgetWithText(ElevatedButton, 'Onayla'));
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Onayla')));
      await tester.pumpAndSettle();
      expect(adapter.calls, contains('/expenses/general/g1/approve'));
    });
  });

  group('fiş / belge', () {
    // Form ve (yükleme sonrası) masraf ayrıntısı aynı kapsayıcıda açılır.
    Widget host({required Expense saved}) => Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            ElevatedButton(
              onPressed: () =>
                  showExpenseFormSheet(context, '', currency: 'TRY', projectLabel: 'Genel masraf (projesiz)'),
              child: const Text('Form'),
            ),
            ElevatedButton(
              onPressed: () => showExpenseDetailSheet(
                context,
                projectId: '',
                expense: saved,
                currency: 'TRY',
                canVoid: false,
                canManageAttachments: true,
                projectLabel: 'Genel masraf',
              ),
              child: const Text('Ayrıntı'),
            ),
          ],
        ),
      ),
    );

    Future<void> fillAndSave(WidgetTester tester) async {
      // Önceki uyarı (ör. reddedilen dosya) kuyruktaki kayıt mesajını
      // bekletmesin.
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
      await tester.enterText(find.widgetWithText(TextFormField, 'Açıklama'), 'Yakıt');
      await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '1.250');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.widgetWithText(ElevatedButton, 'Kaydet'));
    }

    testWidgets('formda fotoğraf/PDF eklenir, kaydetmeden kaldırılır; masraf kaydedilince yüklenir', (tester) async {
      final repo = _FakeAttachmentsRepo();
      final picker = _FakePicker(
        images: [
          (path: '/tmp/fis1.jpg', name: 'fis1.jpg', size: 1000),
          (path: '/tmp/fis2.jpg', name: 'fis2.jpg', size: 1000),
        ],
        files: [
          (path: '/tmp/not.txt', name: 'not.txt', size: 10),
          (path: '/tmp/fatura.pdf', name: 'fatura.pdf', size: 5000),
        ],
      );
      final saved = Expense.fromJson(_generalRow('g9', createdBy: 'field'));
      final adapter = await _pump(
        tester,
        user: myExpensesFieldUser,
        home: host(saved: saved),
        script: {
          '/expenses/general': [
            (status: 201, body: {..._generalRow('g9'), 'attachments': null}),
          ],
        },
        overrides: [
          devicePickerProvider.overrideWithValue(picker),
          expenseAttachmentsRepositoryProvider.overrideWithValue(repo),
        ],
      );
      await tester.tap(find.text('Form'));
      await tester.pumpAndSettle();
      expect(find.text('Fiş / Belge'), findsOneWidget);

      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-kamera')));
      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-galeri')));
      // Dosya seçiciden PDF dışı bir dosya reddedilir.
      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-dosya')));
      expect(find.textContaining('Yalnızca fotoğraf (JPEG, PNG, HEIC) ya da PDF'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-dosya')));
      expect(find.text('fis1.jpg'), findsOneWidget);
      expect(find.text('fis2.jpg'), findsOneWidget);
      expect(find.text('fatura.pdf'), findsOneWidget);

      // Kaydetmeden önce kaldır.
      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-kaldir-fis2.jpg')));
      expect(find.text('fis2.jpg'), findsNothing);
      expect(repo.uploads, isEmpty, reason: 'masraf kaydedilmeden hiçbir şey yüklenmez');

      await fillAndSave(tester);
      expect(adapter.calls, ['/expenses/general']);
      expect(repo.uploads.map((u) => u.name), ['fis1.jpg', 'fatura.pdf']);
      expect(repo.uploads.every((u) => u.projectId == '' && u.expenseId == 'g9'), isTrue);
      expect(find.text('Masraf onaya gönderildi; 2 belge eklendi.'), findsOneWidget);
    });

    testWidgets('yükleme düşerse masraf yine kaydedilir; ayrıntıdan "Tekrar dene" ile yüklenir', (tester) async {
      final repo = _FakeAttachmentsRepo(failNames: {'fis1.jpg'});
      final picker = _FakePicker(images: [(path: '/tmp/fis1.jpg', name: 'fis1.jpg', size: 1000)]);
      final saved = Expense.fromJson(_generalRow('g9', createdBy: 'field'));
      await _pump(
        tester,
        user: myExpensesFieldUser,
        home: host(saved: saved),
        script: {
          '/expenses/general': [
            (status: 201, body: {..._generalRow('g9'), 'attachments': null}),
          ],
        },
        overrides: [
          devicePickerProvider.overrideWithValue(picker),
          expenseAttachmentsRepositoryProvider.overrideWithValue(repo),
        ],
      );
      await tester.tap(find.text('Form'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-kamera')));
      await fillAndSave(tester);
      expect(find.textContaining('Masraf kaydedildi ama 1 belge yüklenemedi'), findsOneWidget);
      expect(find.text('Kaydet'), findsNothing, reason: 'form kapanır: masraf kayıtlı');
      ScaffoldMessenger.of(tester.element(find.text('Ayrıntı'))).removeCurrentSnackBar();
      await tester.pumpAndSettle();

      // Ayrıntıda yüklenemeyen dosya bekler.
      await tester.tap(find.text('Ayrıntı'));
      await tester.pumpAndSettle();
      expect(find.text('fis1.jpg yüklenemedi'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-tekrar-fis1.jpg')));
      expect(repo.uploads.single.name, 'fis1.jpg');
      expect(find.text('fis1.jpg yüklenemedi'), findsNothing);
      expect(find.text('Fiş / Belge (1)'), findsOneWidget);
      expect(find.byKey(const ValueKey('masraf-belge-up1')), findsOneWidget);
    });

    test('belge ekleme/kaldırma: giren ve finans yöneticisi, yalnızca bekleyen/reddedilen masrafta', () {
      final manager = cc.buildUser(
        id: 'mgr',
        roleCode: 'admin',
        permissions: const {'projects.finance.read', 'projects.finance.manage', 'projects.expenses.create'},
      );
      Expense e(String status, {String createdBy = 'field', bool voided = false}) => Expense.fromJson(
        myExpenseRow('x', status: status, createdBy: createdBy, voidedBy: voided ? createdBy : null),
      );
      bool can(User u, Expense x, {bool open = true}) => expenseActionsFor(u, x, open: open).canManageAttachments;
      expect(can(myExpensesFieldUser, e('pending')), isTrue);
      expect(can(myExpensesFieldUser, e('rejected')), isTrue);
      expect(can(myExpensesFieldUser, e('approved')), isFalse, reason: 'onaylanmış masraf salt okunur');
      expect(can(myExpensesFieldUser, e('pending', voided: true)), isFalse, reason: 'geri çekilen salt okunur');
      expect(can(myExpensesFieldUser, e('pending', createdBy: 'other')), isFalse, reason: 'başkasının masrafı');
      expect(can(_approver, e('pending')), isFalse, reason: 'onaylayıcı yalnızca görür');
      expect(can(manager, e('pending', createdBy: 'other')), isTrue);
      expect(can(manager, e('approved', createdBy: 'other')), isFalse, reason: 'finans için de onaylı masraf donmuş');
      expect(can(myExpensesFieldUser, e('pending'), open: false), isFalse, reason: 'kapalı proje');
    });

    testWidgets('ayrıntıda giren belge ekler ve kaldırır', (tester) async {
      final repo = _FakeAttachmentsRepo();
      final picker = _FakePicker(files: [(path: '/tmp/fatura.pdf', name: 'fatura.pdf', size: 5000)]);
      final pending = Expense.fromJson(
        _generalRow(
          'g9',
          attachments: [_attachment('a1', expense: 'g9', mime: 'application/pdf', name: 'eski.pdf')],
        ),
      );
      await _pump(
        tester,
        user: myExpensesFieldUser,
        home: host(saved: pending),
        overrides: [
          devicePickerProvider.overrideWithValue(picker),
          expenseAttachmentsRepositoryProvider.overrideWithValue(repo),
        ],
      );
      await tester.tap(find.text('Ayrıntı'));
      await tester.pumpAndSettle();
      expect(find.text('Fiş / Belge (1)'), findsOneWidget);

      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-ekle')));
      await tester.tap(find.text('Dosya seç (PDF)'));
      await tester.pumpAndSettle();
      expect(repo.uploads.single.name, 'fatura.pdf');
      expect(find.text('Fiş / Belge (2)'), findsOneWidget);

      await _tapVisible(tester, find.byKey(const ValueKey('masraf-belge-kaldir-a1')));
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Kaldır')));
      await tester.pumpAndSettle();
      expect(repo.deletes, ['a1']);
      expect(find.text('Fiş / Belge (1)'), findsOneWidget);
    });
  });
}
