import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// İndirilen teklif PDF'ini cihazda açar; başarıda `null`, açılamazsa
/// kullanıcıya gösterilecek Türkçe mesaj döner.
typedef OfferPdfOpener = Future<String?> Function(String filename, Uint8List bytes);

/// Geçici dizine [filename] adıyla yazar ve OS'un PDF görüntüleyicisiyle
/// açar (proje dosyaları / maaş dökümü ile aynı yol: kimlik doğrulamalı
/// bir uç `url_launcher` ile açılmaz, bayt ApiClient'tan gelir).
Future<String?> openPdfWithSystemViewer(String filename, Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  final result = await OpenFilex.open(file.path, type: 'application/pdf');
  return result.type == ResultType.done ? null : 'PDF açılamadı: ${result.message}';
}

/// Testlerde dosya sistemi / platform eklentisi yerine sahte açıcı verilir.
final offerPdfOpenerProvider = Provider<OfferPdfOpener>((ref) => openPdfWithSystemViewer);
