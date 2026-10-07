import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/access/data/access_repository.dart';
import 'package:arvend/features/access/domain/access_models.dart';
import 'package:arvend/features/employees/data/employees_repository.dart';
import 'package:arvend/features/employees/domain/employee_record.dart';
import 'package:arvend/features/employees/domain/person_name.dart';

import '../../test_utils/fake_api_client.dart';

/// "Kişi = tek kayıt" sözleşmesi (mobile/API_CONTRACT.md "Person = one
/// record"): POST /users personel alanları, cevaptaki employee_link,
/// kullanıcı/personel satırlarındaki bağ alanları, eşleşme önerileri ve
/// backend ile BİREBİR aynı ad karşılaştırması.
void main() {
  group('ad karşılaştırması (backend domain.NormalizePersonName ile aynı)', () {
    test('Türkçe harfler, büyük/küçük harf ve boşluklar', () {
      const same = [
        ('Batuhan İnci', 'BATUHAN INCI'),
        ('Batuhan İnci', 'batuhan inci'),
        ('Batuhan İnci', 'Batuhan Inci'),
        ('Batuhan İnci', '  Batuhan   İnci '),
        ('Ahmet Şahin', 'AHMET SAHIN'),
        ('Gülşen Öztürk', 'gulsen ozturk'),
        ('Çağrı Işık', 'CAGRI ISIK'),
        ('İsmail', 'i̇smail'),
        ('Hâkim Ünal', 'Hakim Unal'),
      ];
      for (final (a, b) in same) {
        expect(samePersonName(a, b), isTrue, reason: '$a ~ $b');
      }
      const different = [('batu', 'Batuhan İnci'), ('Ali Yılmaz', 'Ali Yılmazer'), ('Ali Veli', 'Veli Ali'), ('', '')];
      for (final (a, b) in different) {
        expect(samePersonName(a, b), isFalse, reason: '$a !~ $b');
      }
      expect(normalizePersonName('  Batuhan   İNCİ '), 'batuhan inci');
    });
  });

  group('POST /users personel alanları', () {
    Future<(AccessRepository, FakeHttpClientAdapter)> repo(Map<String, dynamic> body) async {
      final adapter = FakeHttpClientAdapter(
        script: {
          '/users': [(status: 201, body: body)],
        },
      );
      return (AccessRepository(await buildFakeApiClient(adapter)), adapter);
    }

    Map<String, dynamic> userJson({Map<String, dynamic>? link, String? employeeId}) => {
      'id': 'u-new',
      'username': 'batu',
      'full_name': 'batu',
      'role': 'kullanici',
      'is_active': true,
      'organization_role_code': 'field',
      'organization_role_name': 'Saha',
      'employee_id': ?employeeId,
      if (employeeId != null) 'employee_full_name': 'Batuhan İnci',
      if (employeeId != null) 'employee_is_active': true,
      'employee_link': ?link,
    };

    test('verilen alanlar gönderilir, cevaptaki bağ okunur', () async {
      final (r, adapter) = await repo(
        userJson(
          employeeId: 'e9',
          link: {
            'status': 'linked',
            'employee_id': 'e9',
            'employee_full_name': 'Batuhan İnci',
            'employee_is_active': true,
            'message': 'Mevcut personel kaydına (Batuhan İnci) bağlandı.',
          },
        ),
      );
      final created = await r.createUser(
        username: 'batu',
        password: 'gizli-sifre-1',
        fullName: 'batu',
        organizationRoleCode: 'field',
        employeeId: 'e9',
      );
      expect(adapter.requestBodies.single, {
        'username': 'batu',
        'password': 'gizli-sifre-1',
        'full_name': 'batu',
        'organization_role_code': 'field',
        'employee_id': 'e9',
      });
      expect(created.employeeId, 'e9');
      expect(created.employeeFullName, 'Batuhan İnci');
      expect(created.hasEmployee, isTrue);
      expect(created.employeeLink?.status, EmployeeLink.linked);
      expect(created.employeeLink?.isLinked, isTrue);
      expect(created.employeeLink?.message, contains('Batuhan İnci'));
    });

    test('yeni kayıt zorlanır / personel adımı kapatılır', () async {
      final (r, adapter) = await repo(userJson(link: {'status': 'skipped'}));
      final created = await r.createUser(
        username: 'batu',
        password: 'gizli-sifre-1',
        fullName: 'batu',
        organizationRoleCode: 'field',
        createEmployee: false,
        linkSameName: false,
      );
      final body = adapter.requestBodies.single! as Map<String, dynamic>;
      expect(body['create_employee'], false);
      expect(body['link_same_name'], false);
      expect(body.containsKey('employee_id'), isFalse);
      expect(created.hasEmployee, isFalse);
      expect(created.employeeLink?.status, EmployeeLink.skipped);
      expect(created.employeeLink?.isLinked, isFalse);
    });

    test('eski sunucu: alan yoksa bağ yok sayılır', () {
      final u = OrgUser.fromJson({
        'id': '1',
        'username': 'a',
        'full_name': 'A',
        'role': 'kullanici',
        'is_active': true,
      });
      expect(u.employeeId, isNull);
      expect(u.employeeLink, isNull);
    });
  });

  group('personel satırı ve öneriler', () {
    test('bağlı hesabın özeti okunur; gelmezse yalnızca hesabın varlığı bilinir', () {
      final withLogin = EmployeeRecord.fromJson({
        'id': 'e1',
        'full_name': 'Batuhan İnci',
        'user_id': 'u1',
        'user_username': 'batu',
        'user_is_active': false,
      });
      expect(withLogin.hasLogin, isTrue);
      expect(withLogin.userUsername, 'batu');
      expect(withLogin.loginDisabled, isTrue);

      final viewer = EmployeeRecord.fromJson({'id': 'e1', 'full_name': 'Batuhan İnci', 'user_id': 'u1'});
      expect(viewer.hasLogin, isTrue);
      expect(viewer.userUsername, isNull);
      expect(viewer.loginDisabled, isFalse);
    });

    test('GET /employees/link-suggestions', () async {
      final adapter = FakeHttpClientAdapter(
        script: {
          '/employees/link-suggestions': [
            (
              status: 200,
              body: {
                'suggestions': [
                  {
                    'user_id': 'u1',
                    'username': 'selin',
                    'user_full_name': 'Selin Ay',
                    'employee_id': 'e1',
                    'employee_full_name': 'SELİN AY',
                    'employee_position': 'Kalıpçı',
                  },
                ],
              },
            ),
          ],
        },
      );
      final list = await EmployeesRepository(await buildFakeApiClient(adapter)).linkSuggestions();
      expect(adapter.calls, ['/employees/link-suggestions']);
      expect(list.single.username, 'selin');
      expect(list.single.employeeId, 'e1');
      expect(list.single.employeePosition, 'Kalıpçı');
    });
  });
}
