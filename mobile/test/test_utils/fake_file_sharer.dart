import 'package:arvend/core/files/file_share.dart';

/// Paylaşım menüsünün sahtesi: ne paylaşıldığını kaydeder.
class FakeFileSharer implements FileSharer {
  FakeFileSharer({this.error});

  /// Verilirse menü "açılamadı" sayılır.
  final String? error;
  final files = <({String filename, List<int> bytes, String? mimeType, String? text})>[];
  final texts = <String>[];

  @override
  Future<String?> shareFile(String filename, List<int> bytes, {String? mimeType, String? text}) async {
    files.add((filename: filename, bytes: bytes, mimeType: mimeType, text: text));
    return error;
  }

  @override
  Future<String?> shareText(String text, {String? subject}) async {
    texts.add(text);
    return error;
  }
}
