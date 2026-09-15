import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/domain/user.dart';
import '../api/api_providers.dart';
import '../errors/api_exception.dart';

/// Oturum durumu: `AsyncData(null)` = giriş yapılmamış, `AsyncData(User)` =
/// oturum açık. `build()` açılışta GET /auth/me ile oturumu geri yükler
/// (cookie jar'da geçerli bir çerez varsa splash beklemeden hızlıca döner).
/// `ApiClient.onSessionExpired` buraya bağlanır (main.dart) - tek uçuş
/// refresh başarısız olduğunda state'i null'a çeker, go_router'ın redirect'i
/// bunu dinleyip /giris'e yönlendirir.
class AuthController extends AsyncNotifier<User?> {
  @override
  Future<User?> build() async {
    return ref.watch(authRepositoryProvider).me();
  }

  Future<void> login(String username, String password) async {
    state = const AsyncLoading();
    try {
      final user = await ref.read(authRepositoryProvider).login(username, password);
      state = AsyncData(user);
    } on ApiException {
      state = const AsyncData(null);
      rethrow;
    }
  }

  Future<void> logout() async {
    final client = ref.read(apiClientProvider);
    try {
      await ref.read(authRepositoryProvider).logout();
    } on ApiException {
      // Sunucu çağrısı başarısız olsa bile yerel oturumu temizlemeye devam et.
    }
    await client.clearSession();
    state = const AsyncData(null);
  }

  void sessionExpired() {
    state = const AsyncData(null);
  }

  /// setInitialPassword/onboarding adımları User döndürmez (yalnızca
  /// `{ok:true}` ya da onboarding state) -- bu yüzden bu akışlar
  /// tamamlandığında elde tutulan User'ı (mustChangePassword/
  /// onboardingCompleted alanları güncel olsun diye) GET /auth/me ile
  /// tazeler. Oturum bu sırada geçersiz kalmışsa (401->refresh başarısız)
  /// state zaten sessionExpired() ile null'a düşer, burada ayrıca ele
  /// almaya gerek yok.
  Future<void> refresh() async {
    final user = await ref.read(authRepositoryProvider).me();
    if (user != null) state = AsyncData(user);
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, User?>(
  AuthController.new,
);
