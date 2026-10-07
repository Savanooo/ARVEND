import '../../../../core/api/api_client.dart';
import '../../../../core/errors/api_exception.dart';
import '../domain/project_change_order.dart';
import '../domain/project_contract.dart';

/// Proje Sözleşmesi + Ek İşler uçları (backend router.go, web
/// `ContractSection.tsx`/`ChangeOrderSections.tsx` ile aynı çağrılar).
/// Hepsi `projPerm` -- izin + proje üyeliği SUNUCUDA denetlenir:
///
/// Sözleşme (`projects.contracts.*`):
/// - GET  /projects/{id}/contract              read      (yoksa 404 -> null)
/// - POST /projects/{id}/contract              manage    (201)
/// - PUT  /projects/{id}/contract              manage    (yalnızca taslak, aksi 409)
/// - PUT  /projects/{id}/contract/notes        manage    (taslak + aktif, aksi 409)
/// - POST /projects/{id}/contract/activate     lifecycle (taslak -> aktif)
/// - POST /projects/{id}/contract/cancel       lifecycle (taslak -> iptal, {reason} zorunlu)
/// - POST /projects/{id}/contract/complete     lifecycle (aktif -> tamamlandı)
/// - POST /projects/{id}/contract/terminate    lifecycle (aktif -> feshedildi, {reason} zorunlu)
///
/// Ek İşler (`projects.finance.*` -- ek işlerin kendi izni YOK):
/// - GET  /projects/{id}/change-orders                      finance.read -> {change_orders}
/// - GET  /projects/{id}/change-orders/{coId}               finance.read (kalemler + aktif link)
/// - POST /projects/{id}/change-orders                      finance.manage (201)
/// - PUT  /projects/{id}/change-orders/{coId}               finance.manage (yalnızca taslak)
/// - POST /projects/{id}/change-orders/{coId}/send          finance.manage (taslak -> gönderildi + link)
/// - POST /projects/{id}/change-orders/{coId}/send-email    finance.manage ({to, subject, message})
/// - POST /projects/{id}/change-orders/{coId}/revise        finance.manage (yeni taslak döner)
/// - POST /projects/{id}/change-orders/{coId}/cancel        finance.manage (gövdesiz -- gerekçe ALMAZ)
/// - POST /projects/{id}/change-orders/{coId}/record-decision
///                                         change_orders.approve ({decision: approved|rejected, note})
///
/// Ek iş mutasyonlarının TÜMÜ tamamlanmış/iptal edilmiş projede 409 döner
/// (ErrProjectLocked). Müşteri kararı (onay/red) normalde kimlik
/// doğrulamasız `/public/change-orders/{token}` üzerinden verilir; müşteri
/// telefonla/yazılı yanıt verdiyse ekip `record-decision` ile kaydeder --
/// ikisi sunucuda aynı kurallardan geçer (yalnızca gönderilmiş ek iş,
/// eksiltme proje bedelini negatife düşüremez; ikinci karar 409).
class ContractCoRepository {
  ContractCoRepository(this._client);
  final ApiClient _client;

  String _contract(String projectId) => '/projects/$projectId/contract';
  String _changeOrders(String projectId) => '/projects/$projectId/change-orders';

  // ---------- Sözleşme ----------

  /// Sözleşmesi henüz oluşturulmamış proje (backfill YOK) geçerli bir
  /// durumdur: 404 -> `null` ("Sözleşme Oluştur" CTA'sı). Diğer hatalar
  /// (403 dahil) olduğu gibi fırlatılır.
  Future<ProjectContract?> contract(String projectId) async {
    try {
      final json = await _client.get<Map<String, dynamic>>(_contract(projectId));
      return ProjectContract.fromJson(json);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.notFound) return null;
      rethrow;
    }
  }

  Future<ProjectContract> createContract(String projectId) async =>
      ProjectContract.fromJson(await _client.post<Map<String, dynamic>>(_contract(projectId)));

  Future<ProjectContract> updateContractDraft(String projectId, ContractDraftInput input) async =>
      ProjectContract.fromJson(
          await _client.put<Map<String, dynamic>>(_contract(projectId), data: input.toJson()));

  Future<ProjectContract> updateContractNotes(String projectId, String internalNotes) async =>
      ProjectContract.fromJson(await _client.put<Map<String, dynamic>>(
        '${_contract(projectId)}/notes',
        data: {'internal_notes': internalNotes},
      ));

  Future<ProjectContract> activateContract(String projectId) async =>
      ProjectContract.fromJson(await _client.post<Map<String, dynamic>>('${_contract(projectId)}/activate'));

  Future<ProjectContract> completeContract(String projectId) async =>
      ProjectContract.fromJson(await _client.post<Map<String, dynamic>>('${_contract(projectId)}/complete'));

  Future<ProjectContract> cancelContract(String projectId, {required String reason}) async =>
      ProjectContract.fromJson(await _client.post<Map<String, dynamic>>(
        '${_contract(projectId)}/cancel',
        data: {'reason': reason},
      ));

  Future<ProjectContract> terminateContract(String projectId, {required String reason}) async =>
      ProjectContract.fromJson(await _client.post<Map<String, dynamic>>(
        '${_contract(projectId)}/terminate',
        data: {'reason': reason},
      ));

  // ---------- Ek İşler ----------

  Future<List<ProjectChangeOrder>> changeOrders(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>(_changeOrders(projectId));
    return (json['change_orders'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ProjectChangeOrder.fromJson)
        .toList();
  }

  Future<ProjectChangeOrder> changeOrder(String projectId, String changeOrderId) async =>
      ProjectChangeOrder.fromJson(
          await _client.get<Map<String, dynamic>>('${_changeOrders(projectId)}/$changeOrderId'));

  Future<ProjectChangeOrder> createChangeOrder(String projectId, ChangeOrderInput input) async =>
      ProjectChangeOrder.fromJson(
          await _client.post<Map<String, dynamic>>(_changeOrders(projectId), data: input.toJson()));

  Future<ProjectChangeOrder> updateChangeOrder(String projectId, String changeOrderId, ChangeOrderInput input) async =>
      ProjectChangeOrder.fromJson(await _client.put<Map<String, dynamic>>(
        '${_changeOrders(projectId)}/$changeOrderId',
        data: input.toJson(),
      ));

  Future<ProjectChangeOrder> sendChangeOrder(String projectId, String changeOrderId) async =>
      ProjectChangeOrder.fromJson(
          await _client.post<Map<String, dynamic>>('${_changeOrders(projectId)}/$changeOrderId/send'));

  Future<void> sendChangeOrderEmail(String projectId, String changeOrderId, ChangeOrderEmailInput input) =>
      _client.post<void>('${_changeOrders(projectId)}/$changeOrderId/send-email', data: input.toJson());

  /// Yeni TASLAK revizyonu döner; eski kayıt `superseded` olur.
  Future<ProjectChangeOrder> reviseChangeOrder(String projectId, String changeOrderId) async =>
      ProjectChangeOrder.fromJson(
          await _client.post<Map<String, dynamic>>('${_changeOrders(projectId)}/$changeOrderId/revise'));

  Future<ProjectChangeOrder> cancelChangeOrder(String projectId, String changeOrderId) async =>
      ProjectChangeOrder.fromJson(
          await _client.post<Map<String, dynamic>>('${_changeOrders(projectId)}/$changeOrderId/cancel'));

  /// "Müşteri onayladı/reddetti olarak işaretle" -- kim/ne zaman/not
  /// sunucuda kaydedilir; güncel kayıt döner.
  Future<ProjectChangeOrder> recordChangeOrderDecision(
    String projectId,
    String changeOrderId, {
    required bool approved,
    String note = '',
  }) async =>
      ProjectChangeOrder.fromJson(await _client.post<Map<String, dynamic>>(
        '${_changeOrders(projectId)}/$changeOrderId/record-decision',
        data: {'decision': approved ? 'approved' : 'rejected', 'note': note.trim()},
      ));

  // ---------- Yardımcı okumalar ----------

  /// `GET /financial-summary` (finance.read) -- ek işlerle AYNI izin.
  Future<ContractValueSummary> contractValueSummary(String projectId) async => ContractValueSummary.fromJson(
      await _client.get<Map<String, dynamic>>('/projects/$projectId/financial-summary'));

  /// `GET /events` (projects.read) içinden yalnızca `change_order_*`
  /// olayları, eskiden yeniye.
  Future<List<ChangeOrderEvent>> changeOrderEvents(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/events');
    final events = (json['events'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .where((e) => (e['event_type'] as String? ?? '').startsWith(ChangeOrderEvent.prefix))
        .map(ChangeOrderEvent.fromJson)
        .toList();
    // Zaman damgaları farklı ofsetlerle gelebilir -- metin değil an sırası.
    DateTime at(ChangeOrderEvent e) => DateTime.tryParse(e.createdAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
    events.sort((a, b) => at(a).compareTo(at(b)));
    return events;
  }
}
