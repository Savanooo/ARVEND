import 'dart:typed_data';

import '../../../core/api/api_client.dart';
import '../domain/payroll.dart';

class PayrollRepository {
  PayrollRepository(this._client);
  final ApiClient _client;

  /// `month`: "YYYY-MM". Özet + o ayın ödemeleri tek istekte gelir.
  Future<PayrollMonth> month(String month) async {
    final json = await _client.get<Map<String, dynamic>>('/payroll', query: {'month': month});
    return PayrollMonth.fromJson(json);
  }

  Future<SalaryPayment> create({
    required String employeeId,
    required String period,
    required String paymentType,
    required double amount,
    required String paidDate,
    String description = '',
  }) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/payroll',
      data: {
        'employee_id': employeeId,
        'period': period,
        'payment_type': paymentType,
        'amount': amount,
        'paid_date': paidDate,
        'description': description,
      },
    );
    return SalaryPayment.fromJson(json);
  }

  Future<void> delete(String id) => _client.delete<dynamic>('/payroll/$id');

  /// Bir personelin bir ayının maaş dökümü (PDF baytları) -- sunucu üretir,
  /// web'deki "Döküm" ile aynı belge.
  Future<Uint8List> statementPdf(String employeeId, String month) =>
      _client.getBytes('/payroll/$employeeId/statement', queryParameters: {'month': month});
}
