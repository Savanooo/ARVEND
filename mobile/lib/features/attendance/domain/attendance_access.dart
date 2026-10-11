import '../../../core/auth/permissions.dart';
import '../../auth/domain/user.dart';

/// Puantaj (attendance.*) ve maaş (payroll.*) AYRI izinlerdir (backend
/// /payroll uçları yalnızca payroll.* ister, migration 0048). Yalnızca maaş
/// izni verilmiş kişi (ör. muhasebe) Mesai ekranına girer ama puantajı
/// görmez: liste maaş tablosundan kurulur, /attendance çağrılmaz. Menü,
/// ana sayfa kısayolu ve ekranlar bu kararı buradan okur -- biri "Mesai"
/// diğeri "Maaş" demesin.
///
/// Puantaj izni İş Araçları'nın genel kuralıyla (`can`, izin listesi boşsa
/// açık) denetlenir; maaş izni tutar taşıdığı için KATI (`canAccess`).

/// Mesai ekranına girebilir mi (puantaj ya da maaş izni).
bool canOpenAttendanceScreen(User? user) => user.can('attendance.read') || user.canAccess('payroll.read');

/// Puantaj kayıtları okunur mu: puantaj izni varsa ya da maaş izni de yoksa
/// (eski davranış; ekran 403'ü kendisi gösterir).
bool canSeeAttendanceRecords(User? user) => user.can('attendance.read') || !user.canAccess('payroll.read');

/// Menüde/kısayolda ekranın adı: yalnızca maaş izni olanda "Maaş".
String attendanceEntryLabel(User? user) => canSeeAttendanceRecords(user) ? 'Mesai' : 'Maaş';
