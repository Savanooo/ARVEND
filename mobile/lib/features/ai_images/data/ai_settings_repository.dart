import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_providers.dart';
import '../domain/ai_settings.dart';

/// Yapay Zekâ Ayarları uçları (bkz. mobile/API_CONTRACT.md). Üç uç da
/// güncel ayarların TAMAMINI döner: ekran yanıtla durumunu değiştirir,
/// ayrıca tazelemeye gerek kalmaz.
class AiSettingsRepository {
  AiSettingsRepository(this._client);
  final ApiClient _client;

  Future<AiSettings> get() async =>
      AiSettings.fromJson(await _client.get<Map<String, dynamic>>('/ai/settings'));

  /// [monthlyLimit] null = sunucu varsayılanı; [perUserMonthlyLimit] null =
  /// kişi başı sınır yok. Alanlar null da olsa GÖNDERİLİR: sunucu "boş"u
  /// "değiştirme" değil "sınırı kaldır" diye okur.
  Future<AiSettings> update({required bool enabled, int? monthlyLimit, int? perUserMonthlyLimit}) async =>
      AiSettings.fromJson(await _client.put<Map<String, dynamic>>('/ai/settings', data: {
        'enabled': enabled,
        'monthly_limit': monthlyLimit,
        'per_user_monthly_limit': perUserMonthlyLimit,
      }));

  /// [canUse] null = "Rolüne bırak" (kişiye özel ayar silinir).
  Future<AiSettings> setUser(String userId, bool? canUse) async => AiSettings.fromJson(
        await _client.put<Map<String, dynamic>>('/ai/settings/users/$userId', data: {'can_use': canUse}),
      );
}

final aiSettingsRepositoryProvider = Provider<AiSettingsRepository>(
  (ref) => AiSettingsRepository(ref.watch(apiClientProvider)),
);

final aiSettingsProvider = FutureProvider.autoDispose<AiSettings>(
  (ref) => ref.watch(aiSettingsRepositoryProvider).get(),
);
