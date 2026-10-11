import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/files/local_documents.dart';

/// İndirilen teklif PDF'ini cihazda açar; başarıda `null`, açılamazsa
/// kullanıcıya gösterilecek Türkçe mesaj döner.
typedef OfferPdfOpener = Future<String?> Function(String filename, Uint8List bytes);

/// Telefonun belgeler dizinine [filename] adıyla yazar ve OS'un PDF
/// görüntüleyicisiyle açar (proje dosyaları / maaş dökümü ile aynı yol, bkz.
/// core/files/local_documents.dart). Testlerde sahte açıcı verilir.
final offerPdfOpenerProvider = Provider<OfferPdfOpener>((ref) {
  final open = ref.watch(documentOpenerProvider);
  return (filename, bytes) => open(filename, bytes, mimeType: 'application/pdf');
});
