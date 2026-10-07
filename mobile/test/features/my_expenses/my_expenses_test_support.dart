import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;

/// "Masraflarım" testlerinin ortak fikstürleri (backend `GET /expenses/mine`
/// satır biçimi: masraf + project_name/project_no/project_status).

/// Sahadaki kişi: masraf girer, finansı göremez.
final myExpensesFieldUser = cc.buildUser(
  id: 'field',
  roleCode: 'field',
  permissions: const {'projects.read', 'projects.expenses.create', 'projects.operations.read'},
);

Map<String, dynamic> myExpenseRow(
  String id, {
  String status = 'pending',
  String project = 'p1',
  String projectStatus = 'active',
  String createdBy = 'field',
  String? voidedBy,
  String note = '',
  String? costCodeId,
  num amount = 1250,
  String description = 'Hırdavat',
}) =>
    {
      'id': id,
      'project_id': project,
      'category': 'material',
      'description': description,
      'amount': amount,
      'currency': 'TRY',
      'expense_date': '2026-10-06',
      'supplier_name': 'Usta Ali',
      'invoice_no': '',
      'notes': '',
      'created_at': '2026-10-06T08:00:00Z',
      'created_by': createdBy,
      'approval_status': status,
      'decision_note': note,
      if (status != 'pending') 'decided_at': '2026-10-06T12:00:00Z',
      if (voidedBy != null) ...{'voided_at': '2026-10-06T13:00:00Z', 'voided_by': voidedBy},
      'cost_code_id': ?costCodeId,
      'vat_rate': 20,
      'vat_amount': amount * 20 / 120,
      'net_amount': amount - amount * 20 / 120,
      'project_name': project == 'p1' ? 'Kadıköy Ofis Tadilatı' : 'Üsküdar Kafe',
      'project_no': project == 'p1' ? 'PRJ-2026-0007' : 'PRJ-2026-0009',
      'project_status': projectStatus,
    };

List<Map<String, dynamic>> myExpenseRows() => [
      myExpenseRow('m1', description: 'Çivi ve vida'),
      myExpenseRow('m2', status: 'rejected', note: 'Fiş okunmuyor', costCodeId: 'cc9', description: 'Kalıp tahtası'),
      myExpenseRow('m3', status: 'approved', description: 'Nakliye'),
      myExpenseRow('m4', voidedBy: 'field', description: 'Yanlış proje'),
      myExpenseRow('m5', project: 'p2', projectStatus: 'completed', description: 'Kapalı projede'),
    ];

ScriptedResponse mineResponse([List<Map<String, dynamic>>? rows]) => (status: 200, body: {'expenses': rows ?? myExpenseRows(), 'limit': 200});

