import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/data/auth_repository.dart';
import 'api_client.dart';

/// `main()` içinde `await ApiClient.create()` sonrası override edilir
/// (bkz. main.dart) - senkron Provider tercih edildi ki tüm alt sağlayıcılar
/// (repository'ler) FutureProvider zincirine gerek kalmadan `ref.watch`
/// edebilsin; async olan tek şey uygulama açılışındaki tek seferlik kurulum.
final apiClientProvider = Provider<ApiClient>(
  (ref) => throw UnimplementedError('ApiClient main() içinde override edilmeli'),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(apiClientProvider)),
);
