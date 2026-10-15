/// Stok Takibi yolları (Diğer dalı, bkz. inventory_routes.dart).
const inventoryPath = '/diger/stok';
const inventoryDocumentsPath = '/diger/stok/hareketler';
const inventoryWarehousesPath = '/diger/stok/depolar';

String inventoryItemPath(String id) => '/diger/stok/malzeme/${Uri.encodeComponent(id)}';

String inventoryDocumentPath(String id) => '/diger/stok/hareketler/${Uri.encodeComponent(id)}';

/// Yeni fiş: [type] receipt | issue | transfer | waste | count.
String inventoryDocumentFormPath(String type, {String warehouseId = '', String itemId = ''}) {
  final query = {
    if (warehouseId.isNotEmpty) 'depo': warehouseId,
    if (itemId.isNotEmpty) 'malzeme': itemId,
  };
  final base = '/diger/stok/fis/$type';
  return query.isEmpty ? base : Uri(path: base, queryParameters: query).toString();
}
