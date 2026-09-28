import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/theme/app_colors.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/core/widgets/app_data_row.dart';
import 'package:arvend/core/widgets/unsaved_changes_scope.dart';

/// Yönetim ekranlarının ortak parçaları: kaydedilmemiş değişiklik / süren
/// kayıt koruması, çok satırlı veri satırı, yetki görünümleri ve kilitli
/// alan teması.
Widget _app(Widget home) => MaterialApp(theme: AppTheme.light(), home: home);

/// Alttaki sayfanın üstüne itilmiş bir sayfa (geri oku olsun).
Widget _pushed(Widget page) => MaterialApp(
  theme: AppTheme.light(),
  onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const Scaffold(body: Text('ALT SAYFA'))),
  onGenerateInitialRoutes: (_) => [
    MaterialPageRoute(builder: (_) => const Scaffold(body: Text('ALT SAYFA'))),
    MaterialPageRoute(builder: (_) => page),
  ],
);

class _GuardedPage extends StatefulWidget {
  const _GuardedPage({this.busy = false});
  final bool busy;

  @override
  State<_GuardedPage> createState() => _GuardedPageState();
}

class _GuardedPageState extends State<_GuardedPage> {
  bool dirty = false;

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      dirty: dirty,
      busy: widget.busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Düzenle')),
        body: Column(
          children: [
            TextButton(onPressed: () => setState(() => dirty = true), child: const Text('Değiştir')),
            // Aynı sayfada ikinci bir kapsam: onay penceresi yine tek kez.
            UnsavedChangesScope(dirty: dirty, child: const Text('İkinci kart')),
          ],
        ),
      ),
    );
  }
}

void main() {
  group('UnsavedChangesScope', () {
    testWidgets('değişiklik yoksa geri serbest', (tester) async {
      await tester.pumpWidget(_pushed(const _GuardedPage()));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('ALT SAYFA'), findsOneWidget);
    });

    testWidgets('kaydedilmemiş değişiklikte tek onay; Vazgeç kalır, Çık çıkar', (tester) async {
      await tester.pumpWidget(_pushed(const _GuardedPage()));
      await tester.tap(find.text('Değiştir'));
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Kaydedilmemiş değişiklikler var. Çıkmak istiyor musun?'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(find.text('İkinci kart'), findsOneWidget);

      // Android geri hareketi de aynı onayı sorar.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Çık'));
      await tester.pumpAndSettle();
      expect(find.text('ALT SAYFA'), findsOneWidget);
    });

    testWidgets('kayıt sürerken çıkış engellenir ve not gösterilir', (tester) async {
      await tester.pumpWidget(_pushed(const _GuardedPage(busy: true)));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('İkinci kart'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Kaydediliyor, lütfen bitmesini bekle.'), findsOneWidget);
    });
  });

  group('AppDataRow.multiline', () {
    testWidgets('kısa değer aynı satırda sağa yaslı, uzun değer etiketin altında tam', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      const long = 'KDV hariç, toptan liste fiyatı; kesim ve nakliye hariç, fabrika teslim';
      await tester.pumpWidget(
        _app(
          const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                children: [
                  AppDataRow(label: 'Birim', value: 'adet', multiline: true),
                  AppDataRow(label: 'Fiyat esası', value: long, multiline: true),
                ],
              ),
            ),
          ),
        ),
      );
      // Kısa: etiket ve değer aynı yükseklikte.
      expect(tester.getTopLeft(find.text('Birim')).dy, closeTo(tester.getTopLeft(find.text('adet')).dy, 4));
      final labelBox = tester.getRect(find.text('Fiyat esası'));
      final valueBox = tester.getRect(find.text(long));
      // Uzun: değer etiketin ALTINDA, soldan başlar ve kesilmez.
      expect(valueBox.top, greaterThan(labelBox.bottom - 1));
      expect(valueBox.left, closeTo(labelBox.left, 1));
      expect(tester.widget<Text>(find.text(long)).maxLines, isNull);
    });

    testWidgets('trailing verilirse değer yerine bileşen çizilir', (tester) async {
      await tester.pumpWidget(
        _app(const Scaffold(body: AppDataRow(label: 'IBAN', trailing: Text('IBAN kayıtlı')))),
      );
      expect(find.text('IBAN kayıtlı'), findsOneWidget);
    });
  });

  testWidgets('NoAccessView + ReadOnlyNotice ortak görünümü', (tester) async {
    await tester.pumpWidget(
      _app(
        const Scaffold(
          body: Column(
            children: [
              ReadOnlyNotice('Yalnızca görüntüleyebilirsin.'),
              Expanded(child: NoAccessView(message: 'İzin gerekli.', scrollable: true)),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Yetkin yok'), findsOneWidget);
    expect(find.text('İzin gerekli.'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsNWidgets(2));
  });

  testWidgets('kilitli alan düzenlenebilir alandan sönük: açık kenarlık + gri zemin', (tester) async {
    await tester.pumpWidget(
      _app(
        const Scaffold(
          body: Column(
            children: [
              TextField(key: ValueKey('acik'), decoration: InputDecoration(labelText: 'Açık')),
              TextField(key: ValueKey('kilitli'), enabled: false, decoration: InputDecoration(labelText: 'Kilitli')),
            ],
          ),
        ),
      ),
    );
    final theme = AppTheme.light().inputDecorationTheme;
    final disabled = theme.disabledBorder! as OutlineInputBorder;
    expect(disabled.borderSide.color, AppColors.border);
    final fill = theme.fillColor! as WidgetStateColor;
    expect(fill.resolve({WidgetState.disabled}), AppColors.background);
    expect(fill.resolve({}), AppColors.surface);
    // Gerçek çizimde de kilitli alanın kenarlığı düzenlenebilirle aynı renk.
    InputDecorator decorator(String key) =>
        tester.widget<InputDecorator>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(InputDecorator)));
    expect(decorator('kilitli').decoration.enabled, isFalse);
    expect(decorator('acik').decoration.enabled, isTrue);
  });
}
