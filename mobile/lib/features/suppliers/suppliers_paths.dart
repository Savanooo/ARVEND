/// Tedarikçi ekranlarının mutlak yolları -- rotalar "Diğer" dalının
/// (`/diger`) altına kaydedilir (bkz. suppliers_routes.dart). Web ile aynı
/// kısa ad: `/admin/tedarikciler`.
const kSuppliersPath = '/diger/tedarikciler';

String supplierDetailPath(String id) => '$kSuppliersPath/${Uri.encodeComponent(id)}';
