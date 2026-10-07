import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/auth/permissions.dart';
import 'package:arvend/core/update/app_release.dart';
import 'package:arvend/core/update/update_controller.dart';
import 'package:arvend/core/whats_new/whats_new.dart';
import 'package:arvend/core/whats_new/whats_new_content.dart';
import 'package:arvend/features/auth/domain/user.dart';

import '../../features/dashboard/fixtures.dart' show kAllPermissions;

WhatsNewItem _item(String title, {String? permission}) =>
    WhatsNewItem(icon: Icons.star_outline, title: title, body: '$title açıklaması.', permission: permission);

/// Üç sürüm: atlayan kullanıcı için birleştirme ve izin süzmesi.
const _releases = [
  WhatsNewRelease(build: 15, version: '1.5.9', items: [
    WhatsNewItem(icon: Icons.star_outline, title: 'On beş A', body: '.'),
    WhatsNewItem(icon: Icons.star_outline, title: 'On beş B', body: '.', permission: 'projects.finance.manage'),
  ]),
  WhatsNewRelease(build: 17, version: '1.6.1', items: [
    WhatsNewItem(icon: Icons.star_outline, title: 'On yedi A', body: '.'),
  ]),
  WhatsNewRelease(build: 16, version: '1.6.0', items: [
    WhatsNewItem(icon: Icons.star_outline, title: 'On altı A', body: '.', permission: 'offers.read'),
    WhatsNewItem(icon: Icons.star_outline, title: 'On altı B', body: '.'),
  ]),
];

bool _all(String _) => true;

List<String> _titles(WhatsNewNotes? notes) => [for (final i in notes?.items ?? const <WhatsNewItem>[]) i.title];

User _user(Set<String> permissions) => User(
      id: 'u1',
      organizationId: 'org-1',
      username: 'saha',
      fullName: 'Saha Ekibi',
      role: UserRole.kullanici,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      permissions: permissions,
    );

void main() {
  group('whatsNewSince', () {
    test('yalnızca son görülenden yeni sürümler; en yeni sürüm önce', () {
      final notes = whatsNewSince(lastSeenBuild: 14, installedBuild: 17, can: _all, releases: _releases);
      expect(notes!.version, '1.6.1');
      expect(_titles(notes), ['On yedi A', 'On altı A', 'On altı B', 'On beş A', 'On beş B']);

      expect(_titles(whatsNewSince(lastSeenBuild: 16, installedBuild: 17, can: _all, releases: _releases)),
          ['On yedi A']);
    });

    test('görülmüş sürümde ve kurulu build\'den yeni kayıtta hiçbir şey yok', () {
      expect(whatsNewSince(lastSeenBuild: 17, installedBuild: 17, can: _all, releases: _releases), isNull);
      // 17'nin notu eklenmiş ama telefonda henüz 16 var.
      final notes = whatsNewSince(lastSeenBuild: 15, installedBuild: 16, can: _all, releases: _releases);
      expect(notes!.version, '1.6.0');
      expect(_titles(notes), ['On altı A', 'On altı B']);
    });

    test('izni olmayan madde düşer; hiç madde kalmazsa null', () {
      bool onlyRead(String p) => p == 'offers.read';
      expect(_titles(whatsNewSince(lastSeenBuild: 14, installedBuild: 17, can: onlyRead, releases: _releases)),
          ['On yedi A', 'On altı A', 'On altı B', 'On beş A']);

      const gated = [
        WhatsNewRelease(build: 15, version: '1.5.9', items: [
          WhatsNewItem(icon: Icons.star_outline, title: 'Gizli', body: '.', permission: 'projects.finance.manage'),
        ]),
      ];
      expect(whatsNewSince(lastSeenBuild: 14, installedBuild: 15, can: (_) => false, releases: gated), isNull);
    });

    test('en fazla 6 madde, en yeniler', () {
      final many = [
        WhatsNewRelease(build: 15, version: '1.5.9', items: [for (var i = 0; i < 4; i++) _item('Eski $i')]),
        WhatsNewRelease(build: 16, version: '1.6.0', items: [for (var i = 0; i < 4; i++) _item('Yeni $i')]),
      ];
      final notes = whatsNewSince(lastSeenBuild: 14, installedBuild: 16, can: _all, releases: many);
      expect(_titles(notes), ['Yeni 0', 'Yeni 1', 'Yeni 2', 'Yeni 3', 'Eski 0', 'Eski 1']);
    });
  });

  group('latestWhatsNew', () {
    test('kurulu sürüme kadarki en yeni kayıt; maddesi görünmeyen sürüm atlanır', () {
      expect(_titles(latestWhatsNew(installedBuild: 17, can: _all, releases: _releases)), ['On yedi A']);
      expect(latestWhatsNew(installedBuild: 16, can: _all, releases: _releases)!.version, '1.6.0');
      // 16'nın görünen maddesi var ("On altı B"); 17 kurulu değil.
      expect(_titles(latestWhatsNew(installedBuild: 16, can: (_) => false, releases: _releases)), ['On altı B']);
      expect(latestWhatsNew(installedBuild: null, can: _all, releases: _releases)!.version, '1.6.1');
    });
  });

  test('isUpdatedInPlace: Android kaydında güncelleme zamanı kurulumdan sonraysa', () {
    final installed = DateTime(2026, 10, 1, 9);
    expect(isUpdatedInPlace(installTime: installed, updateTime: installed), isFalse);
    expect(isUpdatedInPlace(installTime: installed, updateTime: installed.add(const Duration(days: 6))), isTrue);
    expect(isUpdatedInPlace(installTime: null, updateTime: installed), isFalse);
    expect(isUpdatedInPlace(installTime: installed, updateTime: null), isFalse);
  });

  group('içerik', () {
    test('build numaraları tekil, her sürümde madde var, başlıklar kısa', () {
      final builds = [for (final r in kWhatsNewReleases) r.build];
      expect(builds.toSet(), hasLength(builds.length));
      for (final r in kWhatsNewReleases) {
        expect(r.items, isNotEmpty, reason: r.version);
        expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(r.version), isTrue, reason: r.version);
        for (final item in r.items) {
          final words = item.title.split(' ').length;
          expect(words, inInclusiveRange(2, 4), reason: item.title);
          expect(item.body.trim(), endsWith('.'), reason: item.title);
        }
      }
    });

    test('izin kodları backend\'in gerçek kodları', () {
      for (final r in kWhatsNewReleases) {
        for (final item in r.items) {
          final p = item.permission;
          if (p != null) expect(kAllPermissions, contains(p), reason: item.title);
        }
      }
    });

    test('1.5.9 (build 15) notları: herkese açık maddeler + izne bağlı olanlar', () {
      final notes = whatsNewSince(lastSeenBuild: kWhatsNewLegacyBuild, installedBuild: 15, can: _all);
      expect(notes!.version, '1.5.9');
      expect(_titles(notes), [
        'Masraf onayı',
        'Masrafa KDV',
        'KDV hariç kâr',
        'Teklif PDF',
        'Kolay kapanan formlar',
        'Doğru tutar girişi',
      ]);
      // Yalnızca proje okuyabilen saha çalışanı: finans ve teklif maddeleri yok.
      final field = whatsNewSince(
        lastSeenBuild: kWhatsNewLegacyBuild,
        installedBuild: 15,
        can: _user({'projects.read'}).can,
      );
      expect(_titles(field), ['Kolay kapanan formlar', 'Doğru tutar girişi']);
    });
  });

  group('WhatsNewController', () {
    ProviderContainer containerFor({required bool upgraded, int build = 15, Object? installedError}) {
      final c = ProviderContainer(overrides: [
        installedVersionProvider.overrideWith((ref) async {
          if (installedError != null) throw installedError;
          return InstalledVersion(version: '1.5.9', build: build);
        }),
        appUpdatedInPlaceProvider.overrideWith((ref) async => upgraded),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    Future<int?> stored() async => (await SharedPreferences.getInstance()).getInt(WhatsNewStore.lastSeenBuildKey);

    final owner = _user(kAllPermissions.toSet());

    test('eski sürümün üstüne kurulum: taban 1.5.8, notlar gösterilir', () async {
      SharedPreferences.setMockInitialValues({});
      final c = containerFor(upgraded: true);
      final pending = await c.read(whatsNewControllerProvider).pending(owner);
      expect(await stored(), kWhatsNewLegacyBuild);
      expect(pending!.build, 15);
      expect(pending.notes!.items, hasLength(6));
    });

    test('sıfırdan kurulum: kurulu build sessizce yazılır, gösterilecek bir şey yok', () async {
      SharedPreferences.setMockInitialValues({});
      final c = containerFor(upgraded: false);
      expect(await c.read(whatsNewControllerProvider).pending(owner), isNull);
      expect(await stored(), 15);
    });

    test('kayıt varsa taban DEĞİŞMEZ (güncelleme bilgisine bakılmaz)', () async {
      SharedPreferences.setMockInitialValues({WhatsNewStore.lastSeenBuildKey: 15});
      final c = containerFor(upgraded: true);
      await c.read(whatsNewControllerProvider).prepare();
      expect(await stored(), 15);
      expect(await c.read(whatsNewControllerProvider).pending(owner), isNull);
    });

    test('kurulu sürüm okunamazsa hiçbir şey yazılmaz ve gösterilmez (bir sonraki açılışta yeniden)', () async {
      SharedPreferences.setMockInitialValues({});
      final c = containerFor(upgraded: true, installedError: StateError('PackageInfo yok'));
      expect(await c.read(whatsNewControllerProvider).pending(owner), isNull);
      expect(await stored(), isNull);
    });

    test('markSeen sonrası aynı build bir daha istenmez', () async {
      SharedPreferences.setMockInitialValues({});
      final c = containerFor(upgraded: true);
      final controller = c.read(whatsNewControllerProvider);
      final pending = await controller.pending(owner);
      await controller.markSeen(pending!.build);
      expect(await controller.pending(owner), isNull);
    });
  });
}
