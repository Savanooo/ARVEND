import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_providers.dart';
import '../../notifications/data/notifications_providers.dart';
import '../domain/dashboard.dart';
import 'dashboard_repository.dart';

final dashboardRepositoryProvider = Provider<DashboardRepository>(
  (ref) => DashboardRepository(ref.watch(apiClientProvider)),
);

/// Her başarılı özetin CİHAZDA alındığı an (bkz. DashboardScreen: "5
/// dakikadan eski veri" yenileme kararı). Sunucunun `generated_at`'i cihaz
/// saatiyle KARŞILAŞTIRILMAZ -- cihaz saatindeki kayma eşiği doğrudan
/// kaydırırdı; iki cihaz zamanının farkında kayma birbirini götürür.
final dashboardReceivedAt = Expando<DateTime>('dashboardReceivedAt');

/// Ana sayfanın TEK veri kaynağı (eski üç ayrı çağrının -- /projects,
/// /tasks/mine, bildirim sayacı -- yerine).
final dashboardProvider = FutureProvider.autoDispose<Dashboard>((ref) async {
  final data = await ref.watch(dashboardRepositoryProvider).fetch();
  dashboardReceivedAt[data] = DateTime.now();
  return data;
});

/// Proje seçici araması (`q` boş = ilk 50 açık proje, ada göre).
final projectOptionsProvider = FutureProvider.autoDispose.family<List<ProjectOption>, String>(
  (ref, q) => ref.watch(dashboardRepositoryProvider).projectOptions(q: q),
);

/// Alt gezinmede zaten açık olan "Ana Sayfa" sekmesine tekrar dokunulunca
/// artar (bkz. AppShell) -- ekran başa kayar ve yenilenir.
final homeTabReselectProvider = StateProvider<int>((ref) => 0);

/// Pull-to-refresh / "Tekrar dene": yeni veri gelene kadar bekler (döner
/// gösterge gerçek), eski veri ekranda kalır. Hata durumunu ekran gösterir.
Future<void> refreshDashboard(WidgetRef ref) async {
  try {
    await Future.wait([ref.refresh(dashboardProvider.future), ref.refresh(unreadNotificationCountProvider.future)]);
  } catch (_) {
    // Durum (hata bandı) dashboardProvider üzerinden gösterilir.
  }
}

/// Kurulum rehberi "Gizle" tercihinin anahtarı -- web'in localStorage
/// anahtarıyla AYNI (spec §3.6).
String onboardingHiddenKey(String organizationId, String userId) =>
    'arvend.home.onboarding.hidden.$organizationId.$userId';

/// "Gizle" tercihi (SharedPreferences). Okunamazsa (ör. test ortamı)
/// gizli DEĞİL sayılır -- rehber gösterilir.
class OnboardingHiddenNotifier extends FamilyAsyncNotifier<bool, String> {
  @override
  Future<bool> build(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key) == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> setHidden(bool hidden) async {
    state = AsyncData(hidden);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (hidden) {
        await prefs.setString(arg, '1');
      } else {
        await prefs.remove(arg);
      }
    } catch (_) {
      // Kalıcı yazılamasa da bu oturumda tercih uygulanır.
    }
  }
}

final onboardingHiddenProvider = AsyncNotifierProvider.family<OnboardingHiddenNotifier, bool, String>(
  OnboardingHiddenNotifier.new,
);

/// Deneme süresi uyarısının "Kapat" tercihinin anahtarı -- kişiye ve firmaya
/// özel; değer kapatıldığı İSTANBUL günü ("YYYY-MM-DD").
String trialNoticeDismissKey(String organizationId, String userId) =>
    'arvend.home.trial_notice.dismissed.$organizationId.$userId';

/// İstanbul takvim günü ("YYYY-MM-DD") -- Türkiye sabit UTC+3. "Bugün
/// kapatıldı" cihazın saat diliminden bağımsız olsun diye.
String istanbulDayKey(DateTime now) {
  final t = now.toUtc().add(const Duration(hours: 3));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

/// Uyarının en son kapatıldığı gün (SharedPreferences); hiç kapatılmadıysa ya
/// da okunamazsa null -- uyarı gösterilir. Kapatma yalnızca o gün için
/// geçerlidir: ertesi gün uyarı yeniden çıkar (ürün kararı: günlük kapatma).
class TrialNoticeDismissedNotifier extends FamilyAsyncNotifier<String?, String> {
  @override
  Future<String?> build(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> dismissOn(String day) async {
    state = AsyncData(day);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(arg, day);
    } catch (_) {
      // Kalıcı yazılamasa da bu oturumda gizli kalır.
    }
  }
}

final trialNoticeDismissedProvider = AsyncNotifierProvider.family<TrialNoticeDismissedNotifier, String?, String>(
  TrialNoticeDismissedNotifier.new,
);
