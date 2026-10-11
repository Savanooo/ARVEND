import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Sunucudan inen belgenin (teklif PDF'i, proje dosyası ve fotoğrafı, maaş
/// dökümü) telefondaki TEK dizini: uygulamanın geçici dizininde `belgeler/`.
/// Açmak ya da paylaşmak için önce buraya yazılır; çıkışta dizin topluca
/// silinir (ortak telefonda önceki kişinin dökümü kalmasın). Kimlik
/// doğrulamalı bir uç `url_launcher` ile doğrudan açılmaz -- bayt
/// ApiClient'tan gelir.
class LocalDocuments {
  LocalDocuments({Future<Directory> Function()? baseDirectory}) : _base = baseDirectory ?? getTemporaryDirectory;

  static const directoryName = 'belgeler';

  final Future<Directory> Function() _base;

  Future<Directory> directory() async => Directory('${(await _base()).path}/$directoryName');

  /// [filename] adıyla yazar (ad güvenli hale getirilir, bkz.
  /// [safeFileName]). Disk dolu vb. hatalar `FileSystemException` olarak
  /// fırlar -- çağıran `describeDeviceError` ile anlatır.
  Future<File> save(String filename, List<int> bytes) async {
    final dir = await directory();
    await dir.create(recursive: true);
    final file = File('${dir.path}/${safeFileName(filename)}');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}

final localDocumentsProvider = Provider<LocalDocuments>((ref) => LocalDocuments());

/// Sunucudan gelen dosya adını tek bir yol parçasına çevirir: dizin
/// ayraçları ve kontrol karakterleri atılır, baştaki noktalar (".." ile
/// yukarı çıkma, gizli dosya) kalkar, çok uzun ad uzantısı korunarak
/// kısaltılır. Boş kalırsa [fallback].
String safeFileName(String name, {String fallback = 'dosya'}) {
  var safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  safe = safe.replaceFirst(RegExp(r'^\.+'), '').trim();
  if (safe.isEmpty) return fallback;
  const maxLength = 120;
  if (safe.length <= maxLength) return safe;
  final dot = safe.lastIndexOf('.');
  final ext = dot > 0 && safe.length - dot <= 10 ? safe.substring(dot) : '';
  return '${safe.substring(0, maxLength - ext.length)}$ext';
}

const kNoAppToOpenMessage = 'Bu dosyayı açacak bir uygulama yok. "Paylaş" ile başka bir uygulamaya gönderebilirsin.';

/// İndirilen belgeyi telefona yazar ve işletim sisteminin görüntüleyicisiyle
/// açar; başarıda null, açılamazsa kullanıcıya gösterilecek mesaj. Yazma
/// hatası fırlar. Testler sahtesini verir.
typedef DocumentOpener = Future<String?> Function(String filename, Uint8List bytes, {String? mimeType});

final documentOpenerProvider = Provider<DocumentOpener>((ref) {
  final documents = ref.watch(localDocumentsProvider);
  return (filename, bytes, {mimeType}) async {
    final file = await documents.save(filename, bytes);
    final result = await OpenFilex.open(file.path, type: (mimeType ?? '').isEmpty ? null : mimeType);
    return switch (result.type) {
      ResultType.done => null,
      ResultType.noAppToOpen => kNoAppToOpenMessage,
      _ => 'Dosya açılamadı.',
    };
  };
});
