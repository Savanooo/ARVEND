import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import 'onboarding_repository.dart';

/// İlk-giriş sihirbazı -- /api/v1/onboarding/*.
final onboardingRepositoryProvider = Provider<OnboardingRepository>(
  (ref) => OnboardingRepository(ref.watch(apiClientProvider), basePath: '/onboarding'),
);

/// Onboarding sonrası "Firma Ayarları" düzenleme -- /api/v1/organization/
/// settings/*. AYNI OnboardingRepository sınıfı, farklı basePath.
final organizationSettingsRepositoryProvider = Provider<OnboardingRepository>(
  (ref) => OnboardingRepository(ref.watch(apiClientProvider), basePath: '/organization/settings'),
);
