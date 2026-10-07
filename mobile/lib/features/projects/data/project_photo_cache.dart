import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Şantiye fotoğraflarının cihaz önbelleği (geçici dizin). Bir fotoğrafın
/// içeriği kimliğine bağlı ve değişmez (yeni yükleme = yeni kimlik; silme
/// yumuşak), bu yüzden bir kez indirilen bayt dosyaya yazılır ve Dökümanlar
/// her açıldığında yeniden indirilmez. Eskiden her ziyaret 60 fotoğrafın
/// TAMAMINI yeniden indiriyordu.
///
/// Bellekte değil diskte tutulur: fotoğraf başına birkaç MB'lık bayt
/// yalnızca kutucuk ekrandayken bellekte kalır. Geçici dizini işletim sistemi
/// gerektiğinde boşaltabilir; o zaman yeniden indirilir. Dizin alınamazsa
/// (ör. test ortamı) önbellek sessizce devre dışıdır.
class ProjectPhotoCache {
  ProjectPhotoCache({Future<Directory?> Function()? directory}) : _directory = directory ?? _defaultDirectory;

  final Future<Directory?> Function() _directory;
  Future<Directory?>? _dir;

  static Future<Directory?> _defaultDirectory() async {
    try {
      final tmp = await getTemporaryDirectory();
      return Directory('${tmp.path}/proje-fotograflari');
    } catch (_) {
      return null;
    }
  }

  // Kimlikler UUID'dir; yine de yol parçası olarak yalnızca güvenli
  // karakterler kabul edilir.
  static final _safeId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  Future<File?> _file(String photoId) async {
    if (!_safeId.hasMatch(photoId)) return null;
    final dir = await (_dir ??= _directory());
    return dir == null ? null : File('${dir.path}/$photoId');
  }

  Future<Uint8List?> read(String photoId) async {
    try {
      final file = await _file(photoId);
      if (file == null || !await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String photoId, Uint8List bytes) async {
    try {
      final file = await _file(photoId);
      if (file == null) return;
      await file.parent.create(recursive: true);
      // Yarım yazılmış dosya bozuk görüntü olarak okunmasın: önce geçici
      // ada yaz, sonra yerine taşı.
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
    } catch (_) {
      // Yazılamazsa bir sonraki ziyarette yeniden indirilir.
    }
  }

  Future<void> remove(String photoId) async {
    try {
      final file = await _file(photoId);
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }
}

final projectPhotoCacheProvider = Provider<ProjectPhotoCache>((ref) => ProjectPhotoCache());
