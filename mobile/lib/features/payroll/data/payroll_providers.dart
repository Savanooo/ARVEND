import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/payroll.dart';
import 'payroll_repository.dart';

final payrollRepositoryProvider = Provider<PayrollRepository>((ref) => PayrollRepository(ref.watch(apiClientProvider)));

/// Anahtar "YYYY-MM". Ekleme/silme sonrası bu ay invalidate edilir.
final payrollMonthProvider = FutureProvider.autoDispose.family<PayrollMonth, String>(
  (ref, month) => ref.watch(payrollRepositoryProvider).month(month),
);
