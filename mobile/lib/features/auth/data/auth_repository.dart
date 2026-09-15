import '../../../core/api/api_client.dart';
import '../domain/user.dart';

/// bkz. mobile/API_CONTRACT.md#auth - tüm gövdeler doğrulanmış.
class AuthRepository {
  AuthRepository(this._client);
  final ApiClient _client;

  Future<User> login(String username, String password) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/auth/login',
      data: {'username': username, 'password': password},
    );
    return User.fromJson(json);
  }

  /// Backend'de istek gövdesi YOK - yalnızca refresh_token cookie'si okunur.
  Future<User> refresh() async {
    final json = await _client.post<Map<String, dynamic>>('/auth/refresh');
    return User.fromJson(json);
  }

  Future<void> logout() => _client.post<void>('/auth/logout');

  Future<User?> me() async {
    try {
      final json = await _client.get<Map<String, dynamic>>('/auth/me');
      return User.fromJson(json);
    } on Object {
      return null;
    }
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      _client.patch<void>(
        '/users/me/password',
        data: {'current_password': currentPassword, 'new_password': newPassword},
      );

  /// "Şifre belirle" (must_change_password) akışı -- mevcut şifreyi
  /// İSTEMEZ (changePassword'ün aksine): kullanıcı Super Admin'in verdiği
  /// geçici şifreyle zaten oturum açmış durumda, yalnızca requireAuth
  /// arkasındadır.
  Future<void> setInitialPassword(String newPassword) => _client.post<void>(
        '/users/me/set-initial-password',
        data: {'new_password': newPassword},
      );
}
