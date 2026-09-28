import 'package:shared_preferences/shared_preferences.dart';

/// "Sonra" denen güncellemenin hatırlanması (SharedPreferences).
///
/// Erteleme BUILD'e bağlıdır: süre dolmasa da daha yeni bir build
/// yayınlanırsa tekrar sorulur -- yoksa acil bir düzeltme çıktığında
/// kullanıcı onu bir gün boyunca görmezdi. Zorunlu güncelleme ve elle
/// denetim ertelemeyi DİNLEMEZ (bkz. UpdateController.check).
class UpdatePostponeStore {
  UpdatePostponeStore({
    Future<SharedPreferences> Function()? prefs,
    DateTime Function()? clock,
  })  : _prefs = prefs ?? SharedPreferences.getInstance,
        _clock = clock ?? DateTime.now;

  static const postponeDuration = Duration(hours: 24);

  static const buildKey = 'arvend.update.postponed_build';
  static const atKey = 'arvend.update.postponed_at';

  final Future<SharedPreferences> Function() _prefs;
  final DateTime Function() _clock;

  /// [build] son 24 saat içinde ertelendiyse true. Okunamazsa (ör. test
  /// ortamı) ertelenmemiş sayılır -- en kötü ihtimalle tekrar sorulur.
  Future<bool> isPostponed(int build) async {
    try {
      final prefs = await _prefs();
      if (prefs.getInt(buildKey) != build) return false;
      final at = prefs.getInt(atKey);
      if (at == null) return false;
      final elapsed = _clock().difference(DateTime.fromMillisecondsSinceEpoch(at));
      // Saat geri alındıysa (negatif fark) erteleme sonsuza uzamasın.
      return !elapsed.isNegative && elapsed < postponeDuration;
    } catch (_) {
      return false;
    }
  }

  Future<void> postpone(int build) async {
    try {
      final prefs = await _prefs();
      await prefs.setInt(buildKey, build);
      await prefs.setInt(atKey, _clock().millisecondsSinceEpoch);
    } catch (_) {
      // Kalıcı yazılamazsa en kötü ihtimalle bir sonraki denetimde tekrar
      // sorulur.
    }
  }
}
