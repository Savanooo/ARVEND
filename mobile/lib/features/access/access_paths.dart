/// Kullanıcılar / Roller & Yetkiler ekranlarının tam konumları -- rotalar
/// "Diğer" dalının altına kaydedilir (bkz. access_routes.dart).
abstract final class AccessPaths {
  static const users = '/diger/kullanicilar';
  static const newUser = '/diger/kullanicilar/yeni';
  static String user(String id) => '/diger/kullanicilar/$id';
  static const roles = '/diger/roller';
  static String role(String id) => '/diger/roller/$id';
}
