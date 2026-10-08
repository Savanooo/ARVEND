import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../access/data/access_providers.dart' show orgUserDetailProvider, orgUsersProvider;
import '../../attendance/data/attendance_providers.dart' as attendance;
import '../domain/employee_record.dart';
import 'employees_repository.dart';

final employeesRepositoryProvider = Provider<EmployeesRepository>(
  (ref) => EmployeesRepository(ref.watch(apiClientProvider)),
);

/// Aile anahtarı: '' | 'aktif' | 'pasif'.
final employeesListProvider = FutureProvider.autoDispose.family<List<EmployeeRecord>, String>(
  (ref, filter) => ref.watch(employeesRepositoryProvider).list(filter: filter),
);

final employeeDetailProvider = FutureProvider.autoDispose.family<EmployeeRecord, String>(
  (ref, id) => ref.watch(employeesRepositoryProvider).get(id),
);

/// Hesap <-> personel eşleşme önerileri (bkz. EmployeesRepository.linkSuggestions).
final employeeLinkSuggestionsProvider = FutureProvider.autoDispose<List<EmployeeLinkSuggestion>>(
  (ref) => ref.watch(employeesRepositoryProvider).linkSuggestions(),
);

/// Bir personel eklendi/değişti: listeler, detay, mesai/görev ekranlarının
/// personel seçicisi ve kullanıcı ekranlarındaki "Personel Kaydı" (ad,
/// durum, bağ) tazelensin. Kullanıcı detayı kartından personel sayfasına
/// gidilip orada pasifleştirilen/düzenlenen kayıt, geri dönülünce alttaki
/// kartta eski haliyle kalıyordu.
void invalidateEmployees(WidgetRef ref, {String? id}) => invalidateEmployeesWith(ref.invalidate, id: id);

/// [invalidateEmployees]'in kapsayıcıyla çalışan hali -- kayıt sürerken
/// ekran kapanmış olabilir; çağıran `ProviderScope.containerOf(...)`
/// kapsayıcısını ilk await'ten ÖNCE alır ve `container.invalidate` verir.
void invalidateEmployeesWith(void Function(ProviderOrFamily provider) invalidate, {String? id}) {
  invalidate(employeesListProvider);
  invalidate(employeeLinkSuggestionsProvider);
  if (id != null) invalidate(employeeDetailProvider(id));
  invalidate(attendance.employeesProvider);
  // Bağ değişmiş olabilir (eski ve yeni hesap): bütün aile tazelenir.
  invalidate(orgUserDetailProvider);
  invalidate(orgUsersProvider);
}
