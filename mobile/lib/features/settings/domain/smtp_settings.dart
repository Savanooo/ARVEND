/// `GET/PUT /settings/smtp` yanıtı (backend `smtpSettingsResponse`).
/// Kayıtlı şifre ASLA dönmez -- yalnızca `password_set` bayrağı. Bu
/// modelde de şifre alanı BİLİNÇLİ OLARAK yoktur.
class SmtpSettings {
  final String host;
  final int port;
  final String username;
  final bool passwordSet;
  final String fromEmail;
  final String fromName;
  final bool useTls;
  final bool configured;

  const SmtpSettings({
    required this.host,
    required this.port,
    required this.username,
    required this.passwordSet,
    required this.fromEmail,
    required this.fromName,
    required this.useTls,
    required this.configured,
  });

  factory SmtpSettings.fromJson(Map<String, dynamic> json) => SmtpSettings(
        host: json['host'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
        passwordSet: json['password_set'] as bool? ?? false,
        fromEmail: json['from_email'] as String? ?? '',
        fromName: json['from_name'] as String? ?? '',
        useTls: json['use_tls'] as bool? ?? false,
        configured: json['configured'] as bool? ?? false,
      );

  /// Web formu gibi: kayıtlı port yoksa (0) 587 önerilir.
  int get portOrDefault => port > 0 ? port : 587;
}

/// `PUT /settings/smtp` gövdesi. `password` boşsa `null` gönderilir --
/// backend bu durumda kayıtlı şifreyi DEĞİŞTİRMEZ (bkz. SettingsService.
/// UpdateSmtp).
class SmtpSettingsInput {
  final String host;
  final int port;
  final String username;
  final String password;
  final String fromEmail;
  final String fromName;
  final bool useTls;

  const SmtpSettingsInput({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.fromEmail,
    required this.fromName,
    required this.useTls,
  });

  Map<String, dynamic> toJson() => {
        'host': host.trim(),
        'port': port,
        'username': username.trim(),
        'password': password.isEmpty ? null : password,
        'from_email': fromEmail.trim(),
        'from_name': fromName.trim(),
        'use_tls': useTls,
      };
}

final _emailFormat = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

bool isValidEmail(String value) => _emailFormat.hasMatch(value.trim());
