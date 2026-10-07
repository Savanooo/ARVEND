import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/domain/user.dart';

/// Bu telefonda en son oturum açmış kullanıcı (SharedPreferences).
///
/// İki ayrı kayıt:
/// - [read]/[save]/[clear]: tam kullanıcı -- uygulama ağ YOKKEN açılınca
///   (şantiyede çekmiyor) oturum düşürülmesin, ekranlar kendi "bağlantı yok"
///   durumlarını göstersin diye. Çıkışta / oturum süresi dolunca SİLİNİR:
///   kapanmış bir oturum çevrimdışıyken geri gelmemeli.
/// - [lastUserId]: yalnızca kimlik, çıkışta silinmez -- oturum yokken
///   dokunulan bildirimin, girişte BAŞKA biri oturum açarsa ona açılmaması
///   için (bkz. PushWatcher).
///
/// Şifre/çerez burada TUTULMAZ (çerezler zaten ayrı kavanozda); izin kodları
/// yalnızca menü gizlemek içindir, gerçek sınır backend'de.
class LastUserStore {
  LastUserStore({Future<SharedPreferences> Function()? prefs}) : _prefs = prefs ?? SharedPreferences.getInstance;

  static const userKey = 'arvend.auth.last_user';
  static const userIdKey = 'arvend.auth.last_user_id';

  final Future<SharedPreferences> Function() _prefs;

  /// Okunamazsa (bozuk kayıt, test ortamı) null -- en kötü ihtimalle
  /// çevrimdışı açılışta giriş ekranı görünür.
  Future<User?> read() async {
    try {
      final raw = (await _prefs()).getString(userKey);
      if (raw == null) return null;
      return User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<String?> lastUserId() async {
    try {
      return (await _prefs()).getString(userIdKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(User user) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(userKey, jsonEncode(user.toJson()));
      await prefs.setString(userIdKey, user.id);
    } catch (_) {
      // Yazılamazsa yalnızca çevrimdışı açılış kolaylığı kaybolur.
    }
  }

  Future<void> clear() async {
    try {
      await (await _prefs()).remove(userKey);
    } catch (_) {}
  }
}

final lastUserStoreProvider = Provider<LastUserStore>((ref) => LastUserStore());
