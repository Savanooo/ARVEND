import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/device_errors.dart';
import 'package:arvend/core/files/local_documents.dart';

/// Kamera izni reddi, seçici ve disk hataları sahadaki kullanıcının
/// anlayacağı mesaja çevrilir (mobil-genel-b2).
void main() {
  group('describeDeviceError', () {
    test('kamera izni reddedildi -> Ayarlar önerisi, rapor yok', () {
      final issue = describeDeviceError(PlatformException(code: 'camera_access_denied'), DeviceAction.camera);
      expect(issue.message, contains('Kamera izni kapalı'));
      expect(issue.permissionDenied, isTrue);
      expect(issue.unexpected, isFalse);
    });

    test('fotoğraf izni reddedildi -> Ayarlar önerisi', () {
      final issue = describeDeviceError(PlatformException(code: 'photo_access_denied'), DeviceAction.gallery);
      expect(issue.permissionDenied, isTrue);
    });

    test('kamera yok -> açıklayıcı mesaj, rapor yok', () {
      final issue = describeDeviceError(PlatformException(code: 'no_available_camera'), DeviceAction.camera);
      expect(issue.message, contains('kamera bulunamadı'));
      expect(issue.unexpected, isFalse);
    });

    test('tanınmayan seçici hatası -> işe göre mesaj, ekibe rapor', () {
      final issue = describeDeviceError(PlatformException(code: 'unknown_path'), DeviceAction.pickFile);
      expect(issue.message, 'Dosya seçici açılamadı. Tekrar dene.');
      expect(issue.unexpected, isTrue);
      expect(issue.permissionDenied, isFalse);
    });

    test('telefonda yer yok (ENOSPC) -> yer aç önerisi', () {
      final issue = describeDeviceError(
        const FileSystemException('yazılamadı', '/cache/belgeler/a.pdf', OSError('No space left on device', 28)),
        DeviceAction.saveFile,
      );
      expect(issue.message, 'Telefonda yer kalmadı. Biraz yer açıp tekrar dene.');
      expect(issue.unexpected, isFalse);
    });

    test('seçilen dosya okunamadı -> başka dosya seç önerisi, rapor', () {
      final issue = describeDeviceError(
        const FileSystemException('okunamadı', '/x', OSError('No such file or directory', 2)),
        DeviceAction.pickFile,
      );
      expect(issue.message, contains('Seçilen dosya okunamadı'));
      expect(issue.unexpected, isTrue);
    });
  });

  group('safeFileName', () {
    test('dizin ayraçları ve yukarı çıkma atılır', () {
      expect(safeFileName('../../shared_prefs/x.xml'), '_.._shared_prefs_x.xml');
      expect(safeFileName('..'), 'dosya');
      expect(safeFileName('  '), 'dosya');
      expect(safeFileName('a/b\\c:d.pdf'), 'a_b_c_d.pdf');
    });

    test('Türkçe ad olduğu gibi kalır; çok uzun ad uzantısıyla kısalır', () {
      expect(safeFileName('Teklif-Çatı İşleri.pdf'), 'Teklif-Çatı İşleri.pdf');
      final long = safeFileName('${'ş' * 200}.pdf');
      expect(long.length, 120);
      expect(long, endsWith('.pdf'));
    });
  });

  test('belge telefonun belgeler dizinine güvenli adla yazılır', () async {
    final base = await Directory.systemTemp.createTemp('arvend_docs');
    addTearDown(() => base.delete(recursive: true));
    final docs = LocalDocuments(baseDirectory: () async => base);

    final file = await docs.save('../teklif.pdf', [1, 2, 3]);

    expect(file.parent.path, '${base.path}/${LocalDocuments.directoryName}');
    expect(file.readAsBytesSync(), [1, 2, 3]);
  });
}
