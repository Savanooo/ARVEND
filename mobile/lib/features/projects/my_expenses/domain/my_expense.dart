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

  /// "PRJ-2026-001 · Ataşehir Konut" -- numara yoksa yalnızca ad.
  String get projectLabel => projectNo.isEmpty ? projectName : '$projectNo · $projectName';

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
