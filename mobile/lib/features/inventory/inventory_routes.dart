import 'package:go_router/go_router.dart';

import 'presentation/inventory_document_form_screen.dart';
import 'presentation/inventory_document_screen.dart';
import 'presentation/inventory_documents_screen.dart';
import 'presentation/inventory_item_screen.dart';
import 'presentation/inventory_screen.dart';
import 'presentation/inventory_warehouses_screen.dart';

export 'inventory_paths.dart';

/// "Diğer" dalının (`/diger`) `routes:` listesine eklenecek GÖRELİ rotalar:
///
/// - `stok`                        -> Stok Takibi (malzemeler)
/// - `stok/malzeme/:id`            -> malzemenin sayfası
/// - `stok/fis/:type?depo=&malzeme=` -> yeni fiş (receipt|issue|transfer|waste|count)
/// - `stok/hareketler`             -> bütün fişler
/// - `stok/hareketler/:id`         -> fişin ayrıntısı
/// - `stok/depolar`                -> depolar
///
/// Ekranlar izni kendileri denetler.
final List<RouteBase> inventoryRoutes = [
  GoRoute(
    path: 'stok',
    builder: (context, state) => const InventoryScreen(),
    routes: [
      GoRoute(
        path: 'malzeme/:id',
        builder: (context, state) => InventoryItemScreen(itemId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: 'fis/:type',
        builder: (context, state) => InventoryDocumentFormScreen(
          docType: state.pathParameters['type']!,
          initialWarehouseId: state.uri.queryParameters['depo'] ?? '',
          initialItemId: state.uri.queryParameters['malzeme'] ?? '',
        ),
      ),
      GoRoute(
        path: 'hareketler',
        builder: (context, state) => const InventoryDocumentsScreen(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => InventoryDocumentScreen(documentId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(path: 'depolar', builder: (context, state) => const InventoryWarehousesScreen()),
    ],
  ),
];
