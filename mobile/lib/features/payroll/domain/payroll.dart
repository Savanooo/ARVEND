/// Maaş ve mesai ödemeleri -- backend migration 0048, `GET /payroll?month=`.
///
/// Bir [SalaryPayment] YAPILMIŞ bir ödemedir: "ödenmedi" durumu yoktur
/// (BYZ'de de 56 kaydın 56'sı ödenmişti). Aynı personele aynı ay birden çok
/// ödeme olabilir (avans + kalan).
library;

/// Ödeme türleri -- backend `salary_payments_payment_type_check` ve web
/// `PaymentType` ile BİREBİR aynı küme ve sıra.
const kPaymentTypes = ['maaş', 'avans', 'mesai', 'prim', 'diğer'];

/// Backend'in tek bir ödeme için kabul ettiği üst sınır (service
/// maxPaymentAmount) -- formda aynı sınır, yazım hatasını (fazladan sıfır)
/// kayıttan ÖNCE yakalamak için.
const kMaxPaymentAmount = 100000000.0;

final _periodPattern = RegExp(r'^\d{4}-(0[1-9]|1[0-2])$');

/// 'YYYY-MM' biçiminde geçerli bir ay mı (backend salary_payments_period_check).
bool isValidPeriod(String p) => _periodPattern.hasMatch(p);

class SalaryPayment {
  final String id;
  final String employeeId;
  final String employeeName;
  final String period; // ödemenin ait olduğu ay, YYYY-MM
  final String paymentType;
  final double amount;
  final String paidDate; // ödemenin yapıldığı gün, YYYY-MM-DD
  final String description;

  const SalaryPayment({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.period,
    required this.paymentType,
    required this.amount,
    required this.paidDate,
    required this.description,
  });

  factory SalaryPayment.fromJson(Map<String, dynamic> json) => SalaryPayment(
    id: json['id'] as String,
    employeeId: json['employee_id'] as String,
    employeeName: json['employee_name'] as String? ?? '',
    period: json['period'] as String,
    paymentType: json['payment_type'] as String,
    amount: (json['amount'] as num).toDouble(),
    paidDate: json['paid_date'] as String,
    description: json['description'] as String? ?? '',
  );
}

/// Ayın ödeme tablosunda personel başına bir satır. Kalan borç bilerek YOK:
/// aylık maaş mı yevmiye mi esas alınacağı firmaya göre değişiyor, backend
/// ham sayıları verir (web ile aynı karar).
class PayrollSummaryRow {
  final String employeeId;
  final String fullName;
  final String position;
  final double? salary;
  final double? dailyWage;
  final bool isActive;
  final double workedDays; // geldi = 1, yarım gün = 0.5
  final double workHours;
  final double paidTotal;
  final int paymentCount;

  const PayrollSummaryRow({
    required this.employeeId,
    required this.fullName,
    required this.position,
    required this.salary,
    required this.dailyWage,
    required this.isActive,
    required this.workedDays,
    required this.workHours,
    required this.paidTotal,
    required this.paymentCount,
  });

  factory PayrollSummaryRow.fromJson(Map<String, dynamic> json) => PayrollSummaryRow(
    employeeId: json['employee_id'] as String,
    fullName: json['full_name'] as String,
    position: json['position'] as String? ?? '',
    salary: (json['salary'] as num?)?.toDouble(),
    dailyWage: (json['daily_wage'] as num?)?.toDouble(),
    isActive: json['is_active'] as bool? ?? true,
    workedDays: (json['worked_days'] as num?)?.toDouble() ?? 0,
    workHours: (json['work_hours'] as num?)?.toDouble() ?? 0,
    paidTotal: (json['paid_total'] as num?)?.toDouble() ?? 0,
    paymentCount: (json['payment_count'] as num?)?.toInt() ?? 0,
  );
}

/// `GET /payroll?month=` yanıtı: özet ve tek tek ödemeler AYNI yanıtta.
class PayrollMonth {
  final String period;
  final List<PayrollSummaryRow> summary;
  final List<SalaryPayment> payments;

  const PayrollMonth({required this.period, required this.summary, required this.payments});

  factory PayrollMonth.fromJson(Map<String, dynamic> json) => PayrollMonth(
    period: json['period'] as String,
    summary: (json['summary'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(PayrollSummaryRow.fromJson)
        .toList(),
    payments: (json['payments'] as List? ?? const []).cast<Map<String, dynamic>>().map(SalaryPayment.fromJson).toList(),
  );

  double get paidTotal => summary.fold(0, (sum, r) => sum + r.paidTotal);

  /// Ödeme formunun personel seçicisi: yalnızca aktif personel. Özetten
  /// gelir (aktif personel her zaman özette) -- ödeme girmek için ayrıca
  /// employees.read gerekmesin (web ile aynı).
  List<PayrollSummaryRow> get payableEmployees => summary.where((r) => r.isActive).toList();
}
