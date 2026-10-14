import '../../domain/project.dart';

/// "Masraflarım" satırı (`GET /expenses/mine`, backend migration 0066):
/// kişinin KENDİ girdiği masraf + girildiği proje. Sunucu yalnızca
/// çağıranın masraflarını döndürür, toplam/özet döndürmez.
class MyExpense {
  const MyExpense({
    required this.expense,
    required this.projectName,
    required this.projectNo,
    required this.projectStatus,
  });

  final Expense expense;
  final String projectName;
  final String projectNo;

  /// Kapalı (tamamlanmış/iptal) projede Düzenle/Geri çek gösterilmez.
  final String projectStatus;

  String get projectId => expense.projectId;

  /// Genel (projesiz) masraf (backend migration 0068).
  bool get isGeneral => expense.projectId.isEmpty;

  /// "PRJ-2026-001 · Ataşehir Konut" -- numara yoksa yalnızca ad; genel
  /// masrafta "Genel masraf".
  String get projectLabel =>
      isGeneral ? 'Genel masraf' : (projectNo.isEmpty ? projectName : '$projectNo · $projectName');

  factory MyExpense.fromJson(Map<String, dynamic> json) => MyExpense(
        expense: Expense.fromJson(json),
        projectName: json['project_name'] as String? ?? '',
        projectNo: json['project_no'] as String? ?? '',
        projectStatus: json['project_status'] as String? ?? '',
      );
}

/// Masraflarım süzgeçleri. "Tümü" geri çekilen/iptal edilenleri de gösterir;
/// durum süzgeçleri yalnızca iptal edilmemişleri.
enum MyExpenseFilter {
  all('Tümü'),
  pending('Onay bekliyor'),
  rejected('Reddedildi'),
  approved('Onaylandı');

  const MyExpenseFilter(this.label);
  final String label;

  bool matches(Expense e) => switch (this) {
        MyExpenseFilter.all => true,
        MyExpenseFilter.pending => e.isPending,
        MyExpenseFilter.rejected => !e.isVoided && e.isRejected,
        MyExpenseFilter.approved => !e.isVoided && e.isApproved,
      };
}

/// "Masraflar" ekranı satırı (`GET /expenses`, backend migration 0068):
/// projeli ya da genel masraf + giren kişi.
class ListedExpense {
  const ListedExpense({required this.row, required this.createdByName});

  final MyExpense row;
  final String createdByName;

  Expense get expense => row.expense;

  factory ListedExpense.fromJson(Map<String, dynamic> json) => ListedExpense(
        row: MyExpense.fromJson(json),
        createdByName: json['created_by_name'] as String? ?? '',
      );
}

/// Para birimi başına onaylı ve bekleyen toplam (iptal/ret hariç).
class ExpenseTotals {
  const ExpenseTotals({required this.currency, required this.approved, required this.pending});

  final String currency;
  final double approved;
  final double pending;

  factory ExpenseTotals.fromJson(Map<String, dynamic> json) => ExpenseTotals(
        currency: json['currency'] as String? ?? 'TRY',
        approved: (json['approved'] as num?)?.toDouble() ?? 0,
        pending: (json['pending'] as num?)?.toDouble() ?? 0,
      );
}

/// `GET /expenses` yanıtı. [canSeeAll]: kişi herkesin masrafını görüyor
/// (finans okuma izni); değilse yalnızca kendi girdikleri, toplam yok.
class ExpensesPage {
  const ExpensesPage({required this.rows, required this.canSeeAll, required this.totals, required this.truncated});

  final List<ListedExpense> rows;
  final bool canSeeAll;
  final List<ExpenseTotals> totals;
  final bool truncated;

  factory ExpensesPage.fromJson(Map<String, dynamic> json) => ExpensesPage(
        rows: (json['expenses'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ListedExpense.fromJson)
            .toList(),
        canSeeAll: json['can_see_all'] as bool? ?? false,
        totals: (json['totals'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ExpenseTotals.fromJson)
            .toList(),
        truncated: json['truncated'] as bool? ?? false,
      );
}

/// Masraflar süzgeci: tür (hepsi / genel / projeli) ve durum.
typedef ExpensesQuery = ({String kind, String status});
