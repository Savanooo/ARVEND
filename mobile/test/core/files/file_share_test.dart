import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import 'package:arvend/core/files/file_share.dart';
import 'package:arvend/core/files/local_documents.dart';

/// Sistem paylaşım menüsü (mobil-genel-g4): belge önce telefonun belgeler
/// dizinine (çıkışta silinir) güvenli adla yazılır, sonra menü açılır.
void main() {
  late Directory base;
  late List<ShareParams> opened;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('arvend_share');
    opened = [];
  });
  tearDown(() => base.delete(recursive: true));

  SystemFileSharer sharer({Object? error}) => SystemFileSharer(
        LocalDocuments(baseDirectory: () async => base),
        shareSheet: (params) async {
          if (error != null) throw error;
          opened.add(params);
          return null;
        },
      );

  test('dosya belgeler dizinine yazılır, türü ve yanındaki metniyle menüye gider', () async {
    final result = await sharer().shareFile('Teklif-TKL-2026-0042-R1.pdf', [1, 2, 3],
        mimeType: 'application/pdf', text: '  Teklifimiz ekte  ');

    expect(result, isNull);
    final file = opened.single.files!.single;
    expect(file.path, '${base.path}/${LocalDocuments.directoryName}/Teklif-TKL-2026-0042-R1.pdf');
    expect(file.mimeType, 'application/pdf');
    expect(File(file.path).readAsBytesSync(), [1, 2, 3]);
    expect(opened.single.text, 'Teklifimiz ekte');
  });

  test('boş açıklama ve tür gönderilmez', () async {
    await sharer().shareFile('foto.jpg', [9], mimeType: '', text: '   ');
    expect(opened.single.text, isNull);
    expect(opened.single.files!.single.mimeType, isNull);
  });

  test('yalnızca metin (paylaşım linki)', () async {
    await sharer().shareText('https://app.arvendyapi.com.tr/paylas/abc');
    expect(opened.single.text, 'https://app.arvendyapi.com.tr/paylas/abc');
    expect(opened.single.files, isNull);
  });

  test('menü açılamazsa çökme yok, kullanıcıya mesaj', () async {
    final result = await sharer(error: PlatformException(code: 'error')).shareText('x');
    expect(result, kShareFailedMessage);
  });
}
