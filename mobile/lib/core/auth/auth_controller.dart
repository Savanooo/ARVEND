import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/domain/user.dart';
import '../api/api_providers.dart';
import '../errors/api_exception.dart';
import '../files/local_documents.dart';
import '../push/push_messaging.dart';
import 'last_user_store.dart';

/// `ApiClient.onAccountAccessBlocked` en son hangi sabit sebeple tetiklendiği
/// -- go_router redirect'i (organizationBlocked -> özel ekran) ve LoginScreen
/// (userBlocked -> bilgilendirici mesaj) BUNU okur. Yeni bir girişte (login)
/// VEYA açık logout'ta null'a döner (bkz. AuthController) -- eski bir
/// oturumun sebebinin YENİ oturuma/az önce dönülen giriş ekranına
/// SIZMAMASI için.
final accountAccessIssueProvider = StateProvider<AccountAccessIssue?>((ref) => null);

/// Oturum durumu: `AsyncData(null)` = giriş yapılmamış, `AsyncData(User)` =
/// oturum açık. `build()` açılışta GET /auth/me ile oturumu geri yükler
/// (cookie jar'da geçerli bir çerez varsa splash beklemeden hızlıca döner).
/// `ApiClient.onSessionExpired`/`onAccountAccessBlocked` buraya bağlanır
/// (main.dart) - ikisi de nihayetinde `sessionExpired()`'ı çağırır (TEK
/// yetkili oturum-sıfırlama yolu), go_router'ın redirect'i bunu dinleyip
/// duruma göre /giris veya hesap-engeli ekranına yönlendirir.
class AuthController extends AsyncNotifier<User?> {
  /// Çevrimdışı açılışta son bilinen kullanıcıyla açıldıysa, bağlantı
  /// gelince oturumu sunucuda doğrulamak için tekrar deneme aralığı.
  static const revalidateInterval = Duration(seconds: 30);

  /// Çıkıştaki bildirim adımlarının (anahtarı okuma, sunucu kaydını silme,
  /// anahtarı silme) her biri en fazla bu kadar beklenir: yavaş sunucuda ya
  /// da çekmeyen şantiyede çıkış takılmasın.
  static const pushStepTimeout = Duration(seconds: 6);

  Timer? _revalidateTimer;
  Future<void>? _setupRecheck;

  @override
  Future<User?> build() async {
    ref.onDispose(_cancelRevalidate);
    try {
      final user = await ref.watch(authRepositoryProvider).me();
      _remember(user);
      return user;
    } catch (_) {
      // me() yalnızca oturum DOĞRULANAMADIĞINDA fırlatır (401/403 null
      // döner): ağ yok / sunucuya ulaşılamadı, çerezler yerinde. Şantiyede
      // çekmeyen telefon giriş ekranına atılmaz -- son bilinen kullanıcıyla
      // açılır, ekranlar kendi "bağlantı yok" durumlarını gösterir;
      // bağlantı gelince arka planda doğrulanır (oturum gerçekten bitmişse
      // ilk istek 401 -> refresh başarısız -> sessionExpired ile girişe
      // düşer). Bilinen kullanıcı yoksa hata kalır: router giriş ekranını
      // gösterir (bkz. LoginScreen bağlantı mesajı), sonsuz yükleme yok.
      final cached = await ref.read(lastUserStoreProvider).read();
      if (cached == null) rethrow;
      _scheduleRevalidate();
      return cached;
    }
  }

  void _remember(User? user) {
    final store = ref.read(lastUserStoreProvider);
    unawaited(user == null ? store.clear() : store.save(user));
  }

  void _cancelRevalidate() {
    _revalidateTimer?.cancel();
    _revalidateTimer = null;
  }

  void _scheduleRevalidate() {
    _cancelRevalidate();
    _revalidateTimer = Timer(revalidateInterval, () => unawaited(_revalidate()));
  }

  Future<void> _revalidate() async {
    _revalidateTimer = null;
    final before = state.valueOrNull;
    try {
      final user = await ref.read(authRepositoryProvider).me();
      // Bu arada çıkış/giriş olduysa sonucu yazma.
      if (state.valueOrNull?.id != before?.id) return;
      state = AsyncData(user);
      _remember(user);
    } catch (_) {
      if (state.valueOrNull != null) _scheduleRevalidate();
    }
  }

  Future<void> login(String username, String password) async {
    // Önceki oturumdan kalmış bir hesap-engeli sebebi varsa (ör. kullanıcı
    // engellenmiş ekrandan çıkıp farklı bir hesapla giriş deniyor) YENİ
    // deneme başlarken temizlenir -- eski sebep asla yeni oturuma sızmaz.
    ref.read(accountAccessIssueProvider.notifier).state = null;
    ref.read(apiClientProvider).resetAccountAccessGuard();
    _cancelRevalidate();
    state = const AsyncLoading();
    try {
      final user = await ref.read(authRepositoryProvider).login(username, password);
      state = AsyncData(user);
      _remember(user);
    } on ApiException {
      state = const AsyncData(null);
      rethrow;
    }
  }

  Future<void> logout() async {
    final client = ref.read(apiClientProvider);
    // Önce telefonun bildirim kaydı silinir (oturum hâlâ geçerliyken):
    // çıkış yapılmış telefona başkasının bildirimi düşmesin.
    await _releasePushToken();
    try {
      await ref.read(authRepositoryProvider).logout();
    } on ApiException {
      // Sunucu çağrısı başarısız olsa bile yerel oturumu temizlemeye devam et.
    }
    await client.clearSession();
    _cancelRevalidate();
    _remember(null);
    unawaited(ref.read(localUserFilesProvider).clear());
    ref.read(accountAccessIssueProvider.notifier).state = null;
    state = const AsyncData(null);
  }

  /// Telefonun bildirim kaydı: önce sunucudaki kayıt, sonra -- sunucu
  /// kaydı silinemese de (zaman aşımı, 5xx) -- anahtarın KENDİSİ silinir
  /// (mobil-genel-b3). Geçersizleşen anahtarın sunucu kaydını sunucu ilk
  /// gönderimde kendisi siler (FCM "unregistered").
  Future<void> _releasePushToken() async {
    try {
      final token = await ref.read(pushMessagingProvider).token().timeout(pushStepTimeout);
      if (token != null) {
        await ref.read(pushRepositoryProvider).unregister(token).timeout(pushStepTimeout);
      }
    } catch (_) {
      // Sunucu kaydı silinemese de anahtar aşağıda silinir, çıkış sürer.
    }
    await _deletePushToken();
  }

  /// TEK yetkili oturum-sıfırlama yolu: token süresi doldu (sebep yok) VEYA
  /// hesap engellendi (bkz. accountAccessIssueProvider, main.dart'taki
  /// onAccountAccessBlocked kablosu bu çağrıdan ÖNCE sebebi zaten yazar).
  ///
  /// Telefonun bildirim anahtarı da silinir: süresi dolmuş/engellenmiş
  /// kullanıcının telefonuna bildirim düşmeye devam etmesin (sunucu bir
  /// sonraki gönderimde anahtarı geçersiz görüp kaydı kendisi siler).
  /// Sunucudaki kaydı silme isteği BİLEREK atılmaz: oturum yok, 401 ->
  /// refresh -> tekrar sessionExpired döngüsüne girerdi.
  void sessionExpired() {
    _cancelRevalidate();
    _remember(null);
    unawaited(_deletePushToken());
    unawaited(ref.read(localUserFilesProvider).clear());
    state = const AsyncData(null);
  }

  /// Anahtar silinemezse (ağ yok, Play Hizmetleri yanıt vermedi) oturum yine
  /// kapanır; silme kaydedilir ve bir sonraki açılışta/öne gelişte yeniden
  /// denenir (bkz. [retryPendingPushCleanup]).
  Future<void> _deletePushToken() async {
    final pending = ref.read(pushCleanupStoreProvider);
    // Kayıt beklenmez: tercih deposu çıkışı geciktirmesin.
    try {
      await ref.read(pushMessagingProvider).deleteToken().timeout(pushStepTimeout);
      unawaited(pending.clear());
    } catch (_) {
      unawaited(pending.markPending());
    }
  }

  /// Çıkışta silinemeyen bildirim anahtarını yeniden siler -- YALNIZCA oturum
  /// yokken. Bu arada biri giriş yaptıysa anahtar onun adına kaydedilmiştir
  /// (sunucu kaydı yeni kullanıcıya geçer); silinmez, bekleyen iş unutulur.
  /// PushWatcher açılışta ve öne gelişte çağırır. Hata fırlatmaz.
  Future<void> retryPendingPushCleanup() async {
    // Giriş sürüyorsa (ya da oturum geri yükleniyorsa) dokunulmaz: anahtar
    // birazdan yeni oturumun adına kaydedilecek.
    if (state.isLoading) return;
    final pending = ref.read(pushCleanupStoreProvider);
    if (!await pending.isPending()) return;
    if (state.isLoading) return;
    if (state.valueOrNull != null) {
      await pending.clear();
      return;
    }
    await _deletePushToken();
  }

  /// Oturum açıkken bir iş ucu "önce şifrenizi değiştirin" / "önce firma
  /// kurulumunu tamamlayın" (403) dediyse: kullanıcı bilgisi tazelenir,
  /// router ilgili zorunlu ekrana (şifre belirleme / kurulum) yönlendirir.
  /// Paralel 403'ler tek bir /auth/me paylaşır.
  Future<void> recheckAccountSetup() => _setupRecheck ??= refresh().whenComplete(() => _setupRecheck = null);

  /// setInitialPassword/onboarding adımları User döndürmez (yalnızca
  /// `{ok:true}` ya da onboarding state) -- bu yüzden bu akışlar
  /// tamamlandığında elde tutulan User'ı (mustChangePassword/
  /// onboardingCompleted alanları güncel olsun diye) GET /auth/me ile
  /// tazeler. Oturum bu sırada geçersiz kalmışsa (401->refresh başarısız)
  /// state zaten sessionExpired() ile null'a düşer, burada ayrıca ele
  /// almaya gerek yok.
  ///
  /// Ağ hatasında eldeki kullanıcı korunur (hata yutulur).
  Future<void> refresh() async {
    final User? user;
    try {
      user = await ref.read(authRepositoryProvider).me();
    } catch (_) {
      return;
    }
    if (user != null) {
      state = AsyncData(user);
      _remember(user);
    }
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, User?>(
  AuthController.new,
);
