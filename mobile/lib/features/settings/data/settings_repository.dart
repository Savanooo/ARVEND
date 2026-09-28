import '../../../core/api/api_client.dart';
import '../domain/smtp_settings.dart';

/// `/settings/smtp` -- backend'de `requireAdmin` + `organization.settings.
/// read` (okuma) / `.manage` (kaydet + test). `/organization/settings`
/// (Firma Ayarları) ile KARIŞTIRILMAMALI, ayrı bir uçtur.
class SettingsRepository {
  SettingsRepository(this._client);
  final ApiClient _client;

  Future<SmtpSettings> smtp() async {
    final json = await _client.get<Map<String, dynamic>>('/settings/smtp');
    return SmtpSettings.fromJson(json);
  }

  Future<SmtpSettings> updateSmtp(SmtpSettingsInput input) async {
    final json = await _client.put<Map<String, dynamic>>('/settings/smtp', data: input.toJson());
    return SmtpSettings.fromJson(json);
  }

  /// KAYITLI ayarlarla bir test e-postası gönderir (formdaki kaydedilmemiş
  /// değerlerle DEĞİL -- backend önce veritabanından okur).
  Future<void> sendTestEmail(String to) async {
    await _client.post<dynamic>('/settings/smtp/test', data: {'to': to.trim()});
  }
}
