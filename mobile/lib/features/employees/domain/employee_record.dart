import 'package:intl/intl.dart';

import '../../../core/utils/formatters.dart';

/// Tam personel kaydı -- backend `employeeResponse`. Mesai modülündeki
/// hafif `Employee` (attendance/domain) seçici içindir; bu ise Personel
/// yönetim ekranlarının modelidir.
///
/// ÜCRETLER: `salary`/`dailyWage` backend'den YALNIZCA `employees.manage`
/// sahibine döner (diğerlerine null). Ekranlar ayrıca `canAccess(
/// 'employees.manage')` olmadan ücret alanını HİÇ çizmez.
class EmployeeRecord {
  final String id;
  final String fullName;
  final String phone;
  final String position;
  final double? salary;
  final double? dailyWage;

  /// "YYYY-MM-DD" ya da null.
  final String? startDate;
  final bool isActive;
  final String description;

  /// Bağlı giriş hesabı (users.id) -- null = hesap yok.
  final String? userId;

  /// Bağlı hesabın kullanıcı adı / aktifliği / silinmişliği. Backend
  /// bunları YALNIZCA kullanıcı listesini görebilene (organization.users.
  /// read) gönderir; diğerlerinde null -- o zaman yalnızca [hasLogin]
  /// bilinir.
  final String? userUsername;
  final bool? userIsActive;
  final bool userDeleted;

  const EmployeeRecord({
    required this.id,
    required this.fullName,
    this.phone = '',
    this.position = '',
    this.salary,
    this.dailyWage,
    this.startDate,
    this.isActive = true,
    this.description = '',
    this.userId,
    this.userUsername,
    this.userIsActive,
    this.userDeleted = false,
  });

  factory EmployeeRecord.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'] as String?;
    return EmployeeRecord(
      id: json['id'] as String,
      fullName: json['full_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      position: json['position'] as String? ?? '',
      salary: (json['salary'] as num?)?.toDouble(),
      dailyWage: (json['daily_wage'] as num?)?.toDouble(),
      startDate: json['start_date'] as String?,
      isActive: json['is_active'] as bool? ?? true,
      description: json['description'] as String? ?? '',
      userId: (userId == null || userId.isEmpty) ? null : userId,
      userUsername: json['user_username'] as String?,
      userIsActive: json['user_is_active'] as bool?,
      userDeleted: json['user_deleted'] as bool? ?? false,
    );
  }

  bool get hasLogin => userId != null;

  /// Bağlı hesap var ama giriş yapamıyor (pasif ya da silinmiş) -- yalnızca
  /// hesap bilgisi geldiyse bilinir.
  bool get loginDisabled => hasLogin && (userDeleted || userIsActive == false);

  /// Web Personel tablosuyla aynı: yevmiye varsa "… / gün", yoksa maaş
  /// "… / ay". Yalnızca `employees.manage` ile çağrılmalı.
  String? get wageLabel {
    if (dailyWage != null) return '${Formatters.money(dailyWage!)} / gün';
    if (salary != null) return '${Formatters.money(salary!)} / ay';
    return null;
  }

  /// Liste satırı için kısa hali: "85.000 TL/ay", "2.500 TL/gün" (kuruş
  /// yalnızca varsa: "2.500,50 TL/gün"). Birim ("/ay" - "/gün") dar ekranda
  /// kesilmesin diye bölünmez boşluklarla yazılır. Yalnızca
  /// `employees.manage` ile çağrılmalı.
  String? get wageShortLabel {
    final (amount, unit) = dailyWage != null
        ? (dailyWage!, 'gün')
        : salary != null
        ? (salary!, 'ay')
        : (null, '');
    if (amount == null) return null;
    final whole = amount == amount.roundToDouble();
    final number = (whole ? _wholeFormat : _centsFormat).format(amount);
    return '$number\u00a0TL/$unit';
  }
}

final _wholeFormat = NumberFormat.decimalPattern('tr_TR')..maximumFractionDigits = 0;
final _centsFormat = NumberFormat.decimalPattern('tr_TR')
  ..minimumFractionDigits = 2
  ..maximumFractionDigits = 2;

/// `GET /employees/link-suggestions` satırı: personel kaydı olmayan bir
/// giriş hesabı ile bağlantısız bir personelin BİREBİR aynı adı taşıdığı
/// öneri. Sunucu hiçbir şeyi kendiliğinden bağlamaz; yönetici onaylar.
class EmployeeLinkSuggestion {
  const EmployeeLinkSuggestion({
    required this.userId,
    required this.username,
    required this.userFullName,
    required this.employeeId,
    required this.employeeFullName,
    this.employeePosition = '',
  });

  final String userId;
  final String username;
  final String userFullName;
  final String employeeId;
  final String employeeFullName;
  final String employeePosition;

  factory EmployeeLinkSuggestion.fromJson(Map<String, dynamic> json) => EmployeeLinkSuggestion(
    userId: json['user_id'] as String,
    username: json['username'] as String? ?? '',
    userFullName: json['user_full_name'] as String? ?? '',
    employeeId: json['employee_id'] as String,
    employeeFullName: json['employee_full_name'] as String? ?? '',
    employeePosition: json['employee_position'] as String? ?? '',
  );
}

/// Ücret alanlarının üst sınırı -- sütun numeric(18,2); bu sınır gerçekçi
/// bir üst değer ve sunucunun ham "numeric field overflow" hatasını önler.
const kMaxEmployeeAmount = 999999999999.99;

/// POST/PUT /employees gövdesi. Backend TAM GÜNCELLEME (full-replace)
/// semantiği kullanır: `user_id` boş = bağlantı yok, ücret null = ücret
/// yok. Bu yüzden bir alanı korumak isteyen çağıran mevcut değeri AYNEN
/// geri göndermelidir (bkz. [EmployeeInput.fromRecord]).
class EmployeeInput {
  final String fullName;
  final String phone;
  final String position;
  final double? dailyWage;
  final double? salary;
  final String? startDate;
  final String description;
  final bool isActive;
  final String userId;

  const EmployeeInput({
    required this.fullName,
    this.phone = '',
    this.position = '',
    this.dailyWage,
    this.salary,
    this.startDate,
    this.description = '',
    this.isActive = true,
    this.userId = '',
  });

  /// Mevcut kaydı olduğu gibi (yalnızca [userId] değişerek) yeniden yazmak
  /// için -- "Giriş hesabı aç" akışı. Ücretlerin korunması için kaydın
  /// `employees.manage` ile okunmuş olması GEREKİR (aksi halde null gelir
  /// ve silinirdi); o akış bu izni zaten şart koşar.
  factory EmployeeInput.fromRecord(EmployeeRecord e, {String? userId}) => EmployeeInput(
    fullName: e.fullName,
    phone: e.phone,
    position: e.position,
    dailyWage: e.dailyWage,
    salary: e.salary,
    startDate: e.startDate,
    description: e.description,
    isActive: e.isActive,
    userId: userId ?? e.userId ?? '',
  );

  Map<String, dynamic> toJson() => {
    'full_name': fullName,
    'phone': phone,
    'position': position,
    'daily_wage': dailyWage,
    'salary': salary,
    'start_date': (startDate == null || startDate!.isEmpty) ? null : startDate,
    'description': description,
    'is_active': isActive,
    'user_id': userId,
  };
}

/// Formdaki tutar metnini sayıya çevirir: "1.500" / "1500" / "1.500,50" /
/// "1500,5" / "1500.5". Boş = null (ücret yok). Geçersizse [FormatException].
double? parseAmountInput(String raw) {
  final s = raw.trim().replaceAll(' ', '');
  if (s.isEmpty) return null;
  String normalized;
  if (s.contains(',')) {
    normalized = s.replaceAll('.', '').replaceAll(',', '.');
  } else if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
    // Türkçe binlik ayırıcı: "1.500" = bin beş yüz.
    normalized = s.replaceAll('.', '');
  } else {
    normalized = s;
  }
  final value = double.tryParse(normalized);
  if (value == null || value.isNaN || value.isInfinite) throw FormatException('geçersiz tutar', raw);
  return value;
}

/// Formu doldurmak için: 1500 -> "1500", 1500.5 -> "1500,5".
String amountToInput(double? value) {
  if (value == null) return '';
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toString().replaceAll('.', ',');
}

/// DateTime -> "YYYY-MM-DD".
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
