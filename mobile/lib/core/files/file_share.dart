import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import 'local_documents.dart';

const kShareFailedMessage = 'Paylaşım menüsü açılamadı. Tekrar dene.';

/// Telefonun paylaşım menüsü (WhatsApp, e-posta, Drive, Bluetooth...).
/// Müşteri ve taşeronla iletişim WhatsApp'tan yürüyor; ekran görüntüsü
/// almak yerine belgenin kendisi gider. İzin kuralı indirmeyle aynıdır: bir
/// belgeyi açabilen onu paylaşabilir. Testler sahtesini verir.
abstract interface class FileSharer {
  /// Belgeyi telefonun belgeler dizinine yazıp (çıkışta silinir) paylaşım
  /// menüsünü açar. [text], destekleyen uygulamalarda (WhatsApp, e-posta)
  /// dosyanın yanına eklenir. Menü açılamadıysa kullanıcıya gösterilecek
  /// mesaj; açıldıysa (paylaşılsa da vazgeçilse de) null. Yazma hatası
  /// (ör. telefonda yer yok) fırlar.
  Future<String?> shareFile(String filename, List<int> bytes, {String? mimeType, String? text});

  /// Yalnızca metin/bağlantı (ör. teklifin paylaşım linki).
  Future<String?> shareText(String text, {String? subject});
}

/// Paylaşım menüsünü açan çağrı -- testte sahtesi verilir.
typedef ShareSheet = Future<Object?> Function(ShareParams params);

class SystemFileSharer implements FileSharer {
  SystemFileSharer(this._documents, {ShareSheet? shareSheet}) : _shareSheet = shareSheet ?? SharePlus.instance.share;

  final LocalDocuments _documents;
  final ShareSheet _shareSheet;

  @override
  Future<String?> shareFile(String filename, List<int> bytes, {String? mimeType, String? text}) async {
    final file = await _documents.save(filename, bytes);
    final type = (mimeType ?? '').isEmpty ? null : mimeType;
    return _open(ShareParams(
      files: [XFile(file.path, mimeType: type)],
      text: (text ?? '').trim().isEmpty ? null : text!.trim(),
    ));
  }

  @override
  Future<String?> shareText(String text, {String? subject}) => _open(ShareParams(text: text, subject: subject));

  Future<String?> _open(ShareParams params) async {
    try {
      await _shareSheet(params);
      return null;
    } on PlatformException catch (e) {
      debugPrint('Paylaşım menüsü açılamadı: ${e.code}');
      return kShareFailedMessage;
    } on MissingPluginException {
      return kShareFailedMessage;
    }
  }
}

final fileSharerProvider = Provider<FileSharer>((ref) => SystemFileSharer(ref.watch(localDocumentsProvider)));
