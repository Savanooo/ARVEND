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

/// Şantiye fotoğrafı önbelleğinin dizini (bkz. ProjectPhotoCache).
const kProjectPhotoCacheDirectory = 'proje-fotograflari';

/// Firma Grubu'nun son mesajları ve fotoğrafları (bkz. ChatCache).
const kChatCacheDirectory = 'firma-grubu';

/// share_plus'ın paylaşmadan önce dosyayı kopyaladığı dizin (eklentinin
/// FileProvider'ı yalnızca buradan verir; bir sonraki paylaşıma kadar kalır).
const kSharePlusDirectory = 'share_plus';

/// file_picker'ın seçilen dosyayı yüklemeden önce kopyaladığı dizin.
const kFilePickerDirectory = 'file_picker';

/// image_picker'ın kopyaları geçici dizinin KÖKÜNDE durur: kamerayla
/// çekilen `<uuid><sayı>.jpg`, galeriden seçilen `<uuid>/<ad>` ve
/// küçültülen `scaled_<ad>` (image_picker_android ImagePickerDelegate,
/// FileUtils, ImageResizer). Yalnızca bu adlar silinir, kökteki başka bir
/// şeye dokunulmaz.
final _imagePickerCopy = RegExp(
  r'^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|scaled_)',
  caseSensitive: false,
);

/// Çıkışta telefonda kullanıcıya ait dosya bırakmamak için (mobil-genel-i4):
/// indirilen belgeler, fotoğraf önbelleği, paylaşım kopyaları ve seçicilerin
/// kopyaları (kamerayla çekilen şantiye fotoğrafı, yüklenen dosya) -- hepsi
/// uygulamanın geçici dizininde. Ortak şantiye telefonunda sonraki kişi
/// öncekinin maaş dökümünü, teklifini, fotoğrafını bulmasın. Oturum
/// çerezleri ayrıca silinir (ApiClient.clearSession) ve Android yedeğine
/// hiç girmez (res/xml/data_extraction_rules.xml).
class LocalUserFiles {
  LocalUserFiles({Future<Directory> Function()? baseDirectory}) : _base = baseDirectory ?? getTemporaryDirectory;

  static const directories = [
    LocalDocuments.directoryName,
    kProjectPhotoCacheDirectory,
    kChatCacheDirectory,
    kSharePlusDirectory,
    kFilePickerDirectory,
  ];

  final Future<Directory> Function() _base;

  /// Hata FIRLATMAZ: silinemeyen dizin (ör. test ortamında geçici dizin yok)
  /// çıkışı engellemez.
  Future<void> clear() async {
    final Directory base;
    try {
      base = await _base();
    } catch (_) {
      return;
    }
    for (final name in directories) {
      await _delete(Directory('${base.path}/$name'));
    }
    try {
      await for (final entry in base.list(followLinks: false)) {
        final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (_imagePickerCopy.hasMatch(name)) await _delete(entry);
      }
    } catch (_) {
      // Dizin okunamadı: işletim sistemi geçici dizini zaten zamanla boşaltır.
    }
  }

  static Future<void> _delete(FileSystemEntity entry) async {
    try {
      if (await entry.exists()) await entry.delete(recursive: true);
    } catch (_) {
      // Açık bir dosya vb.: işletim sistemi geçici dizini zaten zamanla boşaltır.
    }
  }
}

final localUserFilesProvider = Provider<LocalUserFiles>((ref) => LocalUserFiles());

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
