import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/smtp_settings.dart';
import 'settings_repository.dart';

final settingsRepositoryProvider =
    Provider<SettingsRepository>((ref) => SettingsRepository(ref.watch(apiClientProvider)));

final smtpSettingsProvider = FutureProvider.autoDispose<SmtpSettings>(
  (ref) => ref.watch(settingsRepositoryProvider).smtp(),
);
