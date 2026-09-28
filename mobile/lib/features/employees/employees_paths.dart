/// Personel ekranlarının tam konumları -- rotalar "Diğer" dalının altına
/// kaydedilir (bkz. employees_routes.dart).
abstract final class EmployeesPaths {
  static const list = '/diger/personel';
  static const create = '/diger/personel/yeni';
  static String detail(String id) => '/diger/personel/$id';
  static String edit(String id) => '/diger/personel/$id/duzenle';
  static String createLogin(String id) => '/diger/personel/$id/giris-hesabi';
}
