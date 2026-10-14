import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_providers.dart';
import '../../suppliers/domain/supplier.dart';
import '../domain/subcontractor.dart';

/// `/subcontractors` uçları (backend migration 0069):
/// - GET  /                         -> kartlar (+ finans okuyabilene ödenen toplamlar)
/// - POST /                         -> yeni kart (kod boşsa TSR-NNNN)
/// - POST /{id}/mark                -> katalogdaki tedarikçiyi Taşeronlar'a ekle
/// - GET  /{id}/ledger              -> kart + projelerdeki işleri + bütün ödemeler
/// - POST /{id}/payments            -> proje dışı ödeme
/// - POST /{id}/payments/{pid}/void -> proje dışı ödemeyi iptal
class SubcontractorsRepository {
  SubcontractorsRepository(this._client);
  final ApiClient _client;

  static const _base = '/subcontractors';

  Future<SubcontractorCardsPage> list() async =>
      SubcontractorCardsPage.fromJson(await _client.get<Map<String, dynamic>>(_base));

  Future<OrganizationSupplier> create({
    required String name,
    String companyName = '',
    String phone = '',
    String specialty = '',
    String taxNumber = '',
    String? iban,
    String notes = '',
  }) async {
    final json = await _client.post<Map<String, dynamic>>(_base, data: {
      'code': '',
      'legal_name': name,
      'trade_name': companyName,
      'phone': phone,
      'specialty': specialty,
      'tax_number': taxNumber,
      'country': 'Türkiye',
      'notes': notes,
      if (iban != null && iban.isNotEmpty) 'iban': iban,
    });
    return OrganizationSupplier.fromJson(json);
  }

  Future<SubcontractorLedger> ledger(String id) async => SubcontractorLedger.fromJson(
        await _client.get<Map<String, dynamic>>('$_base/${Uri.encodeComponent(id)}/ledger'),
      );

  Future<SubcontractorLedgerPayment> createDirectPayment(
    String id, {
    required double amount,
    required String paidDate,
    required String idempotencyKey,
    String currency = 'TRY',
    String description = '',
  }) async {
    final json = await _client.post<Map<String, dynamic>>('$_base/${Uri.encodeComponent(id)}/payments', data: {
      'amount': amount,
      'currency': currency,
      'paid_date': paidDate,
      'description': description,
      'idempotency_key': idempotencyKey,
    });
    return SubcontractorLedgerPayment.fromJson(json);
  }

  Future<void> voidDirectPayment(String id, String paymentId, {String reason = ''}) => _client.post<void>(
        '$_base/${Uri.encodeComponent(id)}/payments/${Uri.encodeComponent(paymentId)}/void',
        data: {'reason': reason},
      );
}

final subcontractorsRepositoryProvider =
    Provider<SubcontractorsRepository>((ref) => SubcontractorsRepository(ref.watch(apiClientProvider)));

final subcontractorCardsProvider = FutureProvider.autoDispose<SubcontractorCardsPage>(
  (ref) => ref.watch(subcontractorsRepositoryProvider).list(),
);

final subcontractorLedgerProvider = FutureProvider.autoDispose.family<SubcontractorLedger, String>(
  (ref, id) => ref.watch(subcontractorsRepositoryProvider).ledger(id),
);
