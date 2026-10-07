import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/auth/domain/user.dart';

import '../../test_utils/fake_api_client.dart';

/// Satın alma / taşeron / teklif formu testlerinin ortak kurulumu: sahte
/// HTTP (yol bazlı yanıt kuyruğu) + gerçek bir go_router yığını (ana sayfa
/// -> form `push`), kaydın ardından gidilen detay rotaları.

const kSuppliersResponse = (
  status: 200,
  body: {
    'suppliers': [
      {'id': 's1', 'code': 'T-001', 'legal_name': 'Demir Çelik A.Ş.', 'trade_name': '', 'is_active': true},
    ],
  },
);

const kCostCodesResponse = (
  status: 200,
  body: {
    'cost_codes': [
      {'id': 'cc1', 'code': '01.01', 'name': 'Genel Giderler', 'is_active': true},
      {'id': 'cc2', 'code': '03.01', 'name': 'Kaba İnşaat', 'is_active': true},
    ],
  },
);

const kProjectResponse = (
  status: 200,
  body: {
    'id': 'p1',
    'project_no': 'PRJ-2026-0001',
    'name': 'Kadıköy Ofis',
    'contract_amount': 1000000,
    'currency': 'TRY',
    'status': 'active',
  },
);

class FakeAuth extends AuthController {
  FakeAuth(this._user);
  final User _user;

  @override
  Future<User?> build() async => _user;
}

User testUser(Set<String> permissions) => User(
      id: 'u1',
      organizationId: 'org1',
      username: 'test',
      fullName: 'Test Kullanıcı',
      role: UserRole.kullanici,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      organizationName: 'Deneme Yapı',
      permissions: permissions,
    );

/// Formu açan `push`'un durumu: kayıttan sonra tamamlanmalı (ana sayfanın
/// hızlı işlem kilidi bu Future'ı bekler).
class FormPushProbe {
  bool completed = false;
  Object? result;
}

/// Formu gerçek bir go_router yığınında açar: `/` -> `/form` (push). Kayıt
/// sonrası gidilen her detay rotası "detay /yol" metniyle çizilir.
Future<FormPushProbe> pumpRoutedForm(
  WidgetTester tester,
  FakeHttpClientAdapter adapter, {
  required Widget form,
  User? user,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await buildFakeApiClient(adapter);
  final probe = FormPushProbe();
  Widget detail(BuildContext context, GoRouterState state) => Scaffold(
        appBar: AppBar(),
        body: Text('detay ${state.uri.path}'),
      );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final result = await context.push<Object?>('/form');
                probe
                  ..completed = true
                  ..result = result;
              },
              child: const Text('Aç'),
            ),
          ),
        ),
      ),
      GoRoute(path: '/form', builder: (_, _) => form),
      GoRoute(path: '/teklifler/:offerId', builder: detail),
      GoRoute(path: '/projeler/:id/satin-alma/siparisler/:poId', builder: detail),
      GoRoute(path: '/projeler/:id/satin-alma/talepler/:prId', builder: detail),
      GoRoute(path: '/projeler/:id/satin-alma/rfqlar/:rfqId', builder: detail),
      GoRoute(path: '/projeler/:id/taseronlar/:scId', builder: detail),
      GoRoute(path: '/projeler/:id/taseronlar/:scId/hakedisler/:claimId', builder: detail),
      GoRoute(path: '/projeler/:id/taseronlar/:scId/degisiklik-emirleri/:coId', builder: detail),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        if (user != null) authControllerProvider.overrideWith(() => FakeAuth(user)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.tap(find.text('Aç'));
  await tester.pumpAndSettle();
  return probe;
}

Future<void> pickDropdown(WidgetTester tester, Finder field, String option) async {
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<void> tapButton(WidgetTester tester, String label) async {
  final button = find.widgetWithText(ElevatedButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Finder formField(String label) => find.widgetWithText(TextFormField, label);

/// `path`'e giden İLK gövdeli isteğin gövdesi (GET'lerde gövde yoktur).
Map<String, dynamic> requestBodyFor(FakeHttpClientAdapter adapter, String path) {
  for (var i = 0; i < adapter.calls.length; i++) {
    final body = adapter.requestBodies[i];
    if (adapter.calls[i] == path && body is Map<String, dynamic>) return body;
  }
  throw StateError('$path için gövdeli istek yok: ${adapter.calls}');
}
