import '../../../../core/errors/api_exception.dart';
import '../../domain/project_lock_text.dart';

/// Finans defteri (tahsilat / masraf / taşeron ödemeleri) ortak metinleri.
/// Ödeme Planı / Faturalar ile aynı metin (finance_plan `kFinanceNoAccessText`).
const kLedgerNoAccessText =
    'Bu projenin finans bilgilerini görüntüleme yetkin yok. Yöneticinden rolüne "Proje finansal verilerini '
    'görüntüleme" iznini eklemesini ya da seni projeye eklemesini isteyebilirsin.';

/// Tamamlanmış/iptal edilmiş projede finans hareketi eklenemez ve iptal
/// edilemez (backend 409, web `locked`).
bool isLedgerLocked(String projectStatus) => projectStatus == 'completed' || projectStatus == 'cancelled';

/// Tüm proje modülleriyle aynı kilit cümlesi (bkz. project_lock_text.dart).
String ledgerLockedText(String projectStatus) => kProjectLockedNoticeText;

bool isForbiddenError(Object? error) => error is ApiException && error.isForbidden;
