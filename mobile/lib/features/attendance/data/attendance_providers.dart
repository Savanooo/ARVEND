import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/attendance.dart';
import 'attendance_repository.dart';

final attendanceRepositoryProvider =
    Provider<AttendanceRepository>((ref) => AttendanceRepository(ref.watch(apiClientProvider)));

final employeesProvider = FutureProvider.autoDispose<List<Employee>>(
  (ref) => ref.watch(attendanceRepositoryProvider).employees(filter: 'aktif'),
);

final attendanceListProvider = FutureProvider.autoDispose.family<List<AttendanceRecord>, String>(
  (ref, month) => ref.watch(attendanceRepositoryProvider).list(month: month),
);
