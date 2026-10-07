import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/dashboard/data/dashboard_providers.dart';
import 'package:arvend/features/dashboard/domain/trial_notice.dart';

/// Deneme süresi uyarısı kuralı (ürün kararı 2026-10-07) ve /auth/me
/// alanlarının okunması -- saf, ağsız.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  Map<String, dynamic> me({
    String roleCode = 'owner',
    String status = 'trial',
    int? days = 3,
    bool expired = false,
    String? endsOn = '2026-10-10',
  }) =>
      {
        'id': 'u1',
        'organization_id': 'org1',
        'username': 'sahip',
        'full_name': 'Sahip',
        'role': 'admin',
        'is_active': true,
        'organization_role_code': roleCode,
        'organization_status': status,
        'trial_ends_at': '2026-10-10T07:00:00Z',
        'trial_ends_on': ?endsOn,
        'trial_days_left': ?days,
        'trial_expired': expired,
      };

  test('/auth/me deneme alanları okunur ve son kullanıcı önbelleğinde korunur', () {
    final user = User.fromJson(me(days: 0));
    expect(user.organizationStatus, 'trial');
    expect(user.trialEndsOn, '2026-10-10');
    expect(user.trialDaysLeft, 0);
    expect(user.trialExpired, isFalse);
    final cached = User.fromJson(user.toJson());
    expect(cached.trialDaysLeft, 0);
    expect(cached.trialEndsOn, '2026-10-10');
    expect(cached.organizationStatus, 'trial');
  });

  test('eski sunucu (alan yok): deneme bilgisi yok, uyarı yok', () {
    final user = User.fromJson({
      'id': 'u1',
      'username': 'x',
      'full_name': 'X',
      'role': 'admin',
      'is_active': true,
      'organization_role_code': 'owner',
    });
    expect(user.organizationStatus, '');
    expect(user.trialDaysLeft, isNull);
    expect(trialNoticeFor(user), isNull);
  });

  test('metinler: kalan gün, bugün, bitti', () {
    expect(trialNoticeFor(User.fromJson(me(days: 7)))!.text, 'Deneme süreniz 7 gün sonra bitiyor.');
    expect(trialNoticeFor(User.fromJson(me(days: 0)))!.text, 'Deneme süreniz bugün bitiyor.');
    final expired = trialNoticeFor(User.fromJson(me(days: -2, expired: true, endsOn: '2026-10-05')))!;
    expect(expired.expired, isTrue);
    expect(expired.text, 'Deneme süreniz 05.10.2026 tarihinde bitti. Devam etmek için ARVEND ile iletişime geçin.');
  });

  test('gösterilmeyen durumlar', () {
    expect(trialNoticeFor(null), isNull);
    expect(trialNoticeFor(User.fromJson(me(days: 8))), isNull, reason: '7 günden fazla');
    expect(trialNoticeFor(User.fromJson(me(status: 'active'))), isNull, reason: 'deneme değil');
    expect(trialNoticeFor(User.fromJson(me(days: null, endsOn: null))), isNull, reason: 'bitiş tarihi yok');
    for (final role in ['finance', 'project_manager', 'field', 'legacy_user', '']) {
      expect(trialNoticeFor(User.fromJson(me(roleCode: role, days: -1, expired: true))), isNull, reason: role);
    }
    expect(trialNoticeFor(User.fromJson(me(roleCode: 'admin', days: 1))), isNotNull, reason: 'Yönetici görür');
  });

  test('kapatma günü İstanbul takvimiyle', () {
    // 21:30Z = İstanbul'da ertesi gün 00:30.
    expect(istanbulDayKey(DateTime.utc(2026, 10, 7, 21, 30)), '2026-10-08');
    expect(istanbulDayKey(DateTime.utc(2026, 10, 7, 20, 59)), '2026-10-07');
  });
}
