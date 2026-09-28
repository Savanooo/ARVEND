/// Maliyet kodu ekranlarının mutlak yolları -- rotalar "Diğer" dalının
/// (`/diger`) altına kaydedilir (bkz. cost_codes_routes.dart). Web ile aynı
/// kısa ad: `/admin/maliyet-kodlari`.
const kCostCodesPath = '/diger/maliyet-kodlari';

String costCodeDetailPath(String id) => '$kCostCodesPath/${Uri.encodeComponent(id)}';
