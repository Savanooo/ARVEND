import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_client.dart';
import '../../../../core/api/api_providers.dart';
import '../domain/my_expense.dart';

/// `GET /expenses/mine[?project_id=]` (`projects.expenses.create`, backend
/// migration 0066) -> `{expenses: [...], limit}`: yalnızca oturumdaki
/// kişinin girdiği masraflar, erişebildiği projelerde, en yeni giriş önce
/// (en fazla `limit`). Finans okuma izni gerekmez; toplam yoktur.
class MyExpensesRepository {
  MyExpensesRepository(this._client);
  final ApiClient _client;

  Future<List<MyExpense>> list({String? projectId}) async {
    final json = await _client.get<Map<String, dynamic>>(
      '/expenses/mine',
      query: {if (projectId != null && projectId.isNotEmpty) 'project_id': projectId},
    );
    return (json['expenses'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(MyExpense.fromJson)
        .toList();
  }
}

final myExpensesRepositoryProvider =
    Provider<MyExpensesRepository>((ref) => MyExpensesRepository(ref.watch(apiClientProvider)));

/// Anahtar: proje süzgeci (null = tüm projeler). Masraf yazan her yol
/// (form, ayrıntıdaki düzelt/geri çek/onay) bunu tazeler -- bkz.
/// invalidateProjectLedger ve masraf formu.
final myExpensesProvider = FutureProvider.autoDispose.family<List<MyExpense>, String?>(
  (ref, projectId) => ref.watch(myExpensesRepositoryProvider).list(projectId: projectId),
);
