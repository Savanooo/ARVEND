import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crash/crash_reporter.dart';
import '../platform/app_settings.dart';

/// Telefonun kendisinden gelen hatanın (izin, seçici, disk) hangi işte
/// çıktığı -- mesaj buna göre seçilir.
enum DeviceAction {
  /// Kamerayla fotoğraf çekme.
  camera,

  /// Galeriden fotoğraf seçme.
  gallery,

  /// Dosya seçici.
  pickFile,

  /// İndirilen belgeyi telefona yazma (açmak/paylaşmak için).
  saveFile,
}

/// Kullanıcıya gösterilecek hali.
@immutable
class DeviceIssue {
  const DeviceIssue(this.message, {this.permissionDenied = false, this.unexpected = false});

  final String message;

  /// İzin kapalı: mesajın yanında telefonun ayarlarına götüren düğme olur.
  final bool permissionDenied;

  /// Tanınmayan hata: ekibe (fatal olmayan) rapor gider.
  final bool unexpected;
}

/// ENOSPC -- Android/Linux'ta "No space left on device".
const _kNoSpaceErrno = 28;

/// Kamera/galeri/dosya seçici ve diske yazma hatalarını sahadaki kullanıcının
/// anlayacağı Türkçe mesaja çevirir. Eskiden bunlar hiç yakalanmıyordu:
/// kamera izni reddedilince "Fotoğraf Çek" hiçbir şey yapmıyor, telefonda
/// yer yokken dosya sessizce açılmıyordu (mobil-genel-b2).
DeviceIssue describeDeviceError(Object error, DeviceAction action) {
  if (error is PlatformException) {
    switch (error.code) {
      case 'camera_access_denied':
        return const DeviceIssue(
          "Kamera izni kapalı. Fotoğraf çekebilmek için Ayarlar'dan ARVEND'e kamera izni ver.",
          permissionDenied: true,
        );
      case 'photo_access_denied':
        return const DeviceIssue(
          "Fotoğraflara erişim izni kapalı. Ayarlar'dan ARVEND'e fotoğraf izni ver.",
          permissionDenied: true,
        );
      case 'no_available_camera':
        return const DeviceIssue('Bu telefonda kullanılabilir bir kamera bulunamadı.');
    }
    return DeviceIssue(switch (action) {
      DeviceAction.camera => 'Kamera açılamadı. Tekrar dene.',
      DeviceAction.gallery => 'Galeri açılamadı. Tekrar dene.',
      DeviceAction.pickFile => 'Dosya seçici açılamadı. Tekrar dene.',
      DeviceAction.saveFile => 'Dosya telefona kaydedilemedi. Tekrar dene.',
    }, unexpected: true);
  }
  if (error is FileSystemException) {
    final os = error.osError;
    if (os != null && (os.errorCode == _kNoSpaceErrno || os.message.toLowerCase().contains('no space'))) {
      return const DeviceIssue('Telefonda yer kalmadı. Biraz yer açıp tekrar dene.');
    }
    return DeviceIssue(switch (action) {
      DeviceAction.camera || DeviceAction.gallery => 'Fotoğraf okunamadı. Tekrar dene.',
      DeviceAction.pickFile => 'Seçilen dosya okunamadı. Başka bir dosya seçip tekrar dene.',
      DeviceAction.saveFile => 'Dosya telefona kaydedilemedi. Tekrar dene.',
    }, unexpected: true);
  }
  return const DeviceIssue('Bir sorun oluştu. Tekrar dene.', unexpected: true);
}

/// [describeDeviceError]'ın mesajını alt bantta gösterir; izin kapalıysa
/// "Ayarlar" düğmesi telefonun bu uygulamaya ait ayar sayfasını açar.
/// Tanınmayan hata ekibe raporlanır ([where]: hangi ekranda).
void showDeviceIssue(
  BuildContext context,
  WidgetRef ref,
  Object error,
  StackTrace stack,
  DeviceAction action, {
  required String where,
}) {
  final issue = describeDeviceError(error, action);
  if (issue.unexpected) {
    unawaited(ref.read(crashReporterProvider).recordError(error, stack, reason: '$where (${action.name})'));
  }
  if (!context.mounted) return;
  final openSettings = ref.read(appSettingsOpenerProvider);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(issue.message),
        duration: Duration(seconds: issue.permissionDenied ? 8 : 4),
        action: issue.permissionDenied
            ? SnackBarAction(label: 'Ayarlar', onPressed: () => unawaited(openSettings()))
            : null,
      ),
    );
}
