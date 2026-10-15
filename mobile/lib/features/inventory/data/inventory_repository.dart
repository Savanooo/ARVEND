import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_providers.dart';
import '../domain/inventory.dart';

/// `/inventory` uçları (backend migration 0072). Okuma inventory.read;
/// kart, giriş, çıkış, aktarım ve ek inventory.manage; depo, fire, sayım ve
/// fiş iptali inventory.adjust.
class InventoryRepository {
  InventoryRepository(this._client);
  final ApiClient _client;

  static const _base = '/inventory';

  Future<InventorySummary> summary() async =>
      InventorySummary.fromJson(await _client.get<Map<String, dynamic>>('$_base/summary'));

  Future<List<InventoryWarehouse>> warehouses() async {
    final json = await _client.get<Map<String, dynamic>>('$_base/warehouses');
    return (json['warehouses'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(InventoryWarehouse.fromJson)
        .toList();
  }

  Future<InventoryWarehouse> saveWarehouse({
    String? id,
    required String name,
    String address = '',
    String notes = '',
    bool? isActive,
  }) async {
    final data = {'name': name, 'address': address, 'notes': notes, 'is_active': ?isActive};
    final json = id == null
        ? await _client.post<Map<String, dynamic>>('$_base/warehouses', data: data)
        : await _client.put<Map<String, dynamic>>('$_base/warehouses/${Uri.encodeComponent(id)}', data: data);
    return InventoryWarehouse.fromJson(json);
  }

  Future<List<WarehouseBalance>> warehouseBalances(String warehouseId) async {
    final json = await _client.get<Map<String, dynamic>>('$_base/warehouses/${Uri.encodeComponent(warehouseId)}/balances');
    return (json['balances'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(WarehouseBalance.fromJson)
        .toList();
  }

  Future<InventoryItemsPage> items({String? warehouseId, bool includeInactive = false}) async =>
      InventoryItemsPage.fromJson(await _client.get<Map<String, dynamic>>('$_base/items', query: {
        if (warehouseId != null && warehouseId.isNotEmpty) 'warehouse_id': warehouseId,
        if (includeInactive) 'include_inactive': '1',
      }));

  Future<InventoryItemDetail> item(String id) async =>
      InventoryItemDetail.fromJson(await _client.get<Map<String, dynamic>>('$_base/items/${Uri.encodeComponent(id)}'));

  Future<InventoryItem> itemByBarcode(String code) async => InventoryItem.fromJson(
        await _client.get<Map<String, dynamic>>('$_base/items/by-barcode/${Uri.encodeComponent(code)}'),
      );

  Future<InventoryItem> saveItem({String? id, required Map<String, dynamic> data}) async {
    final json = id == null
        ? await _client.post<Map<String, dynamic>>('$_base/items', data: data)
        : await _client.put<Map<String, dynamic>>('$_base/items/${Uri.encodeComponent(id)}', data: data);
    return InventoryItem.fromJson(json);
  }

  /// Fiş türü -> uç.
  static String documentPath(String docType) => switch (docType) {
        kDocReceipt => '$_base/receipts',
        kDocIssue => '$_base/issues',
        kDocTransfer => '$_base/transfers',
        kDocWaste => '$_base/waste',
        kDocCount => '$_base/counts',
        _ => throw ArgumentError('fiş türü: $docType'),
      };

  Future<InventoryDocument> postDocument(String docType, Map<String, dynamic> data) async =>
      InventoryDocument.fromJson(await _client.post<Map<String, dynamic>>(documentPath(docType), data: data));

  Future<List<InventoryDocumentSummary>> documents({
    String? type,
    String? warehouseId,
    String? itemId,
    int limit = 100,
    int offset = 0,
  }) async {
    final json = await _client.get<Map<String, dynamic>>('$_base/documents', query: {
      if (type != null && type.isNotEmpty) 'type': type,
      if (warehouseId != null && warehouseId.isNotEmpty) 'warehouse_id': warehouseId,
      if (itemId != null && itemId.isNotEmpty) 'item_id': itemId,
      'limit': '$limit',
      'offset': '$offset',
    });
    return (json['documents'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(InventoryDocumentSummary.fromJson)
        .toList();
  }

  Future<InventoryDocument> document(String id) async =>
      InventoryDocument.fromJson(await _client.get<Map<String, dynamic>>('$_base/documents/${Uri.encodeComponent(id)}'));

  Future<InventoryDocument> reverse(String id, String reason) async => InventoryDocument.fromJson(
        await _client.post<Map<String, dynamic>>('$_base/documents/${Uri.encodeComponent(id)}/reverse',
            data: {'reason': reason}),
      );

  Future<InventoryDocument> uploadAttachment(String id, String path, String filename) async {
    final form = FormData.fromMap({'file': await MultipartFile.fromFile(path, filename: filename)});
    return InventoryDocument.fromJson(
      await _client.post<Map<String, dynamic>>('$_base/documents/${Uri.encodeComponent(id)}/attachment', data: form),
    );
  }

  Future<Uint8List> attachment(String id) =>
      _client.getBytes('$_base/documents/${Uri.encodeComponent(id)}/attachment');
}

final inventoryRepositoryProvider =
    Provider<InventoryRepository>((ref) => InventoryRepository(ref.watch(apiClientProvider)));

final inventorySummaryProvider = FutureProvider.autoDispose<InventorySummary>(
  (ref) => ref.watch(inventoryRepositoryProvider).summary(),
);

final inventoryWarehousesProvider = FutureProvider.autoDispose<List<InventoryWarehouse>>(
  (ref) => ref.watch(inventoryRepositoryProvider).warehouses(),
);

/// Malzemeler; anahtar seçili depo ('' = bütün depolar).
final inventoryItemsProvider = FutureProvider.autoDispose.family<InventoryItemsPage, String>(
  (ref, warehouseId) => ref.watch(inventoryRepositoryProvider).items(warehouseId: warehouseId),
);

final inventoryItemProvider = FutureProvider.autoDispose.family<InventoryItemDetail, String>(
  (ref, id) => ref.watch(inventoryRepositoryProvider).item(id),
);

/// Hareketler; anahtar fiş türü ('' = hepsi).
final inventoryDocumentsProvider = FutureProvider.autoDispose.family<List<InventoryDocumentSummary>, String>(
  (ref, type) => ref.watch(inventoryRepositoryProvider).documents(type: type),
);

final inventoryDocumentProvider = FutureProvider.autoDispose.family<InventoryDocument, String>(
  (ref, id) => ref.watch(inventoryRepositoryProvider).document(id),
);

/// Bir stok işleminden sonra listeler ve özet tazelenir.
void invalidateInventory(void Function(ProviderOrFamily) invalidate) {
  invalidate(inventorySummaryProvider);
  invalidate(inventoryWarehousesProvider);
  invalidate(inventoryItemsProvider);
  invalidate(inventoryItemProvider);
  invalidate(inventoryDocumentsProvider);
  invalidate(inventoryDocumentProvider);
}
