import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart' show DownloadRejected;
import '../errors/api_exception.dart';
import 'apk_installer.dart';
import 'app_release.dart';
import 'update_repository.dart';

enum UpdateFailureKind {
  /// İndirme 401 döndü -- önce giriş yapılmalı.
  loginRequired,

  /// İnen dosyanın boyutu/SHA-256 özeti sunucudakiyle tutmadı -- dosya
  /// silindi, kurulum ekranı AÇILMADI.
  checksumMismatch,

  /// Sunucu elimizdeki kayıttan BAŞKA bir APK sunuyor (ETag = özet farklı;
  /// bu arada yeni sürüm yayınlanmış) -- gövde hiç indirilmedi. Sürüm
  /// bilgisi yeniden sorulup güncel sürümle baştan başlanmalı.
  releaseChanged,

  /// Sunucuda indirilecek dosya yok (404).
  notFound,

  /// Ağ/sunucu hatası.
  network,

  /// Dosya cihaza yazılamadı/okunamadı (ör. yer yok).
  storage,
}

class UpdateFailure implements Exception {
  const UpdateFailure(this.kind, [this.detail]);

  final UpdateFailureKind kind;

  /// Ağ hatalarında backend'in/ApiClient'ın Türkçe mesajı.
  final String? detail;

  String get message => switch (kind) {
        UpdateFailureKind.loginRequired => 'Güncellemeyi indirmek için önce giriş yap.',
        UpdateFailureKind.checksumMismatch =>
          'İndirilen dosya doğrulanamadı; güvenliğin için kurulum iptal edildi. Tekrar deneyebilirsin.',
        UpdateFailureKind.releaseChanged =>
          'Bu arada sunucuda daha yeni bir sürüm yayınlandı. Tekrar dene; güncel sürüm indirilecek.',
        UpdateFailureKind.notFound => 'Sunucuda güncelleme dosyası bulunamadı. Daha sonra tekrar dene.',
        UpdateFailureKind.network => detail ?? 'Güncelleme indirilemedi. Bağlantını kontrol edip tekrar dene.',
        UpdateFailureKind.storage =>
          'Güncelleme dosyası kaydedilemedi. Telefonda yeterli boş alan olduğundan emin ol.',
      };

  @override
  String toString() => 'UpdateFailure($kind)';
}

/// Kullanıcı indirmeyi iptal etti -- hata değil, sessizce kapanır.
class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// Dosyanın SHA-256 özeti (küçük harf hex). ~60 MB'ı UI thread'inde
/// hash'lemek ekranı dondurur; bu yüzden ayrı bir isolate'te ve dosya
/// belleğe alınmadan akış halinde hesaplanır.
Future<String> sha256OfFile(String path) => Isolate.run(() async {
      final digest = await crypto.sha256.bind(File(path).openRead()).first;
      return digest.toString();
    });

/// İndir -> doğrula -> kurulum ekranını aç. Ağ ve kurulum ekranı
/// soyutlamalarla verilir ([UpdateDownloader], [ApkInstaller]) ki SHA
/// uyuşmazlığı gibi yollar gerçek ağ olmadan test edilebilsin.
///
/// Dosyalar uygulamanın ÖZEL cache dizininde, yalnızca bu modülün kullandığı
/// `app-update/` alt klasöründe tutulur (başka hiçbir uygulama yazamaz;
/// open_filex'in FileProvider'ı `cache-path`'i kapsar). İndirme önce
/// `.part` dosyasına yapılır, özet tutarsa asıl adına taşınır -- yarım ya
/// da doğrulanmamış bir dosya asla kurulum ekranına verilmez.
class UpdateInstallService {
  UpdateInstallService({
    required this._downloader,
    required this._installer,
    required this._baseDirectory,
    Future<String> Function(String path)? hashFile,
  }) : _hashFile = hashFile ?? sha256OfFile;

  static const dirName = 'app-update';

  final UpdateDownloader _downloader;
  final ApkInstaller _installer;
  final Future<Directory> Function() _baseDirectory;
  final Future<String> Function(String path) _hashFile;

  static String fileNameFor(AppRelease release) => 'arvend-${release.build}.apk';

  Future<Directory> _updateDir() async {
    final base = await _baseDirectory();
    final dir = Directory('${base.path}/$dirName');
    await dir.create(recursive: true);
    return dir;
  }

  /// APK'yı indirir ve doğrular; başarılıysa doğrulanmış dosyayı döner.
  ///
  /// Aynı build daha önce indirilip doğrulandıysa (ör. kullanıcı kurulum
  /// izni için Ayarlar'a gidip döndü) yeniden indirilmez, yalnızca özeti
  /// tekrar kontrol edilir. Diğer bütün eski/yarım APK'lar silinir.
  Future<File> prepare(
    AppRelease release, {
    required CancelToken cancelToken,
    void Function(int received, int total)? onProgress,
    VoidCallback? onVerifying,
  }) async {
    final File target;
    final File part;
    try {
      final dir = await _updateDir();
      target = File('${dir.path}/${fileNameFor(release)}');
      part = File('${target.path}.part');
      await _deleteAllExcept(dir, keep: target.path);

      if (await target.exists()) {
        if (await _matches(target, release, onVerifying)) return target;
        await _deleteQuietly(target);
      }
    } on FileSystemException catch (e) {
      debugPrint('Güncelleme: dosya hazırlanamadı: ${e.message}');
      throw const UpdateFailure(UpdateFailureKind.storage);
    }

    try {
      await _downloader.download(
        part.path,
        expectedSha256: release.sha256,
        onProgress: (received, total) => onProgress?.call(received, total > 0 ? total : release.size),
        cancelToken: cancelToken,
      );
    } catch (e) {
      await _deleteQuietly(part);
      if (cancelToken.isCancelled) throw const UpdateCancelled();
      if (e is DownloadRejected) throw const UpdateFailure(UpdateFailureKind.releaseChanged);
      if (e is ApiException) {
        throw switch (e.kind) {
          ApiErrorKind.unauthorized => const UpdateFailure(UpdateFailureKind.loginRequired),
          ApiErrorKind.notFound => const UpdateFailure(UpdateFailureKind.notFound),
          _ => UpdateFailure(UpdateFailureKind.network, e.message),
        };
      }
      if (e is FileSystemException) throw const UpdateFailure(UpdateFailureKind.storage);
      throw const UpdateFailure(UpdateFailureKind.network);
    }

    if (cancelToken.isCancelled) {
      await _deleteQuietly(part);
      throw const UpdateCancelled();
    }

    try {
      if (!await _matches(part, release, onVerifying)) {
        await _deleteQuietly(part);
        throw const UpdateFailure(UpdateFailureKind.checksumMismatch);
      }
      return await part.rename(target.path);
    } on FileSystemException catch (e) {
      debugPrint('Güncelleme: dosya doğrulanamadı: ${e.message}');
      await _deleteQuietly(part);
      throw const UpdateFailure(UpdateFailureKind.storage);
    }
  }

  /// Boyut (biliniyorsa) ve SHA-256 özeti sunucudakiyle BİREBİR aynı mı.
  Future<bool> _matches(File file, AppRelease release, VoidCallback? onVerifying) async {
    if (release.size > 0 && await file.length() != release.size) return false;
    onVerifying?.call();
    final digest = await _hashFile(file.path);
    return digest.toLowerCase() == release.sha256;
  }

  /// Doğrulanmış APK için Android'in kurulum ekranını açar.
  Future<ApkInstallResult> install(File apk) => _installer.install(apk.path);

  Future<void> openInstallPermissionSettings() => _installer.openInstallPermissionSettings();

  /// İndirilmiş APK'ları siler; [keepBuild] verilirse o build'in dosyası
  /// kalır. Başarılı bir güncellemeden sonra ~60 MB cache'te kalmasın diye
  /// açılışta çağrılır. Hata vermez.
  Future<void> cleanup({int? keepBuild}) async {
    try {
      final base = await _baseDirectory();
      final dir = Directory('${base.path}/$dirName');
      if (!await dir.exists()) return;
      final keep = keepBuild == null ? null : '${dir.path}/arvend-$keepBuild.apk';
      await _deleteAllExcept(dir, keep: keep);
    } catch (e) {
      debugPrint('Güncelleme: eski dosyalar silinemedi: $e');
    }
  }

  Future<void> _deleteAllExcept(Directory dir, {String? keep}) async {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path != keep) await _deleteQuietly(entity);
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Silinemeyen dosya bir sonraki cleanup'ta tekrar denenir.
    }
  }
}
