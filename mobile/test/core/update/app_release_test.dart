import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/update/app_release.dart';

import 'update_fakes.dart';

void main() {
  group('AppRelease.fromJson', () {
    test('sözleşmedeki tüm alanlar okunur', () {
      final r = AppRelease.fromJson(releaseJson(minBuild: 2));
      expect(r.platform, 'android');
      expect(r.build, 3);
      expect(r.version, '1.2.0');
      expect(r.sha256, kSha);
      expect(r.size, 62418702);
      expect(r.notes, 'Uzaktan güncelleme eklendi.');
      expect(r.minBuild, 2);
      expect(r.publishedAt, DateTime.utc(2026, 9, 28, 9, 30));
      expect(r.isPublished, isTrue);
    });

    test('sürüm yoksa ({"platform":"android","build":0}) yayınlanmış sayılmaz, güncelleme önerilmez', () {
      final r = AppRelease.fromJson({'platform': 'android', 'build': 0});
      expect(r.build, 0);
      expect(r.version, '');
      expect(r.sha256, '');
      expect(r.size, 0);
      expect(r.notes, '');
      expect(r.minBuild, 0);
      expect(r.publishedAt, isNull);
      expect(r.isPublished, isFalse);
      expect(r.isNewerThan(0), isFalse);
      expect(r.isMandatoryFor(0), isFalse);
    });

    test('eksik ya da yanlış tipli alanlar hata fırlatmaz, varsayılana düşer', () {
      final r = AppRelease.fromJson({
        'build': '4',
        'version': 12,
        'size': 1.5e6,
        'min_build': null,
        'published_at': 'dün',
        'sha256': null,
      });
      expect(r.build, 4);
      expect(r.version, '');
      expect(r.size, 1500000);
      expect(r.minBuild, 0);
      expect(r.publishedAt, isNull);
      // Özet yoksa dosya doğrulanamaz -- sürüm "yok" sayılır.
      expect(r.isPublished, isFalse);
      expect(r.isNewerThan(1), isFalse);
      expect(AppRelease.fromJson(const {}).isPublished, isFalse);
    });

    test('SHA-256 büyük harfle gelirse küçültülür; 64 hex değilse yayınlanmış sayılmaz', () {
      expect(AppRelease.fromJson(releaseJson(sha256: kSha.toUpperCase())).sha256, kSha);
      expect(AppRelease.fromJson(releaseJson(sha256: kSha.toUpperCase())).isPublished, isTrue);
      expect(AppRelease.fromJson(releaseJson(sha256: kSha.substring(1))).isPublished, isFalse);
      expect(AppRelease.fromJson(releaseJson(sha256: '${kSha.substring(1)}g')).isPublished, isFalse);
    });

    test('version boşsa ekranda build numarası gösterilir', () {
      expect(AppRelease.fromJson(releaseJson(version: '')).displayVersion, 'build 3');
      expect(AppRelease.fromJson(releaseJson()).displayVersion, '1.2.0');
    });
  });

  group('güncelleme var mı / zorunlu mu', () {
    test('yalnızca sunucudaki build kurulu olandan BÜYÜKSE güncelleme var', () {
      final r = AppRelease.fromJson(releaseJson(build: 3));
      expect(r.isNewerThan(2), isTrue);
      expect(r.isNewerThan(3), isFalse);
      expect(r.isNewerThan(4), isFalse);
    });

    test('kurulu build min_build altındaysa zorunlu', () {
      final r = AppRelease.fromJson(releaseJson(build: 3, minBuild: 3));
      expect(r.isMandatoryFor(2), isTrue);
      expect(r.isMandatoryFor(1), isTrue);
    });

    test('kurulu build min_build\'e eşit ya da büyükse zorunlu DEĞİL', () {
      final r = AppRelease.fromJson(releaseJson(build: 5, minBuild: 3));
      expect(r.isNewerThan(3), isTrue);
      expect(r.isMandatoryFor(3), isFalse);
      expect(r.isMandatoryFor(4), isFalse);
      expect(AppRelease.fromJson(releaseJson(build: 5)).isMandatoryFor(1), isFalse);
    });

    test('min_build yeni sürümden büyük yazılsa bile kurulacak bir şey yoksa zorunlu sayılmaz (kilitlenme yok)', () {
      final r = AppRelease.fromJson(releaseJson(build: 3, minBuild: 10));
      expect(r.isMandatoryFor(3), isFalse);
      expect(r.isMandatoryFor(4), isFalse);
      expect(r.isMandatoryFor(2), isTrue);
    });

    test('doğrulanamayan (özetsiz) sürüm zorunlu da olamaz', () {
      final r = AppRelease.fromJson(releaseJson(sha256: '', minBuild: 9));
      expect(r.isMandatoryFor(1), isFalse);
    });
  });
}
