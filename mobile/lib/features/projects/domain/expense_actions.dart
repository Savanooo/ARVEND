import '../../../core/auth/permissions.dart';
import '../../auth/domain/user.dart';
import 'project.dart';

/// Proje finansını yönetme izni -- masrafın bağlarını (ek iş, bütçe kalemi,
/// maliyet kodu) yazmak ve HER masrafı düzenlemek/iptal etmek için.
const kExpenseFinanceManagePermission = 'projects.finance.manage';

/// Bir masrafta kişinin yapabilecekleri (backend migration 0066 kuralları).
/// Finans listesi, "Masraflarım" ve masraf ayrıntısı AYNI kararı kullanır;
/// yalnızca görünürlüktür, sunucu her işlemi yeniden denetler.
class ExpenseActions {
  const ExpenseActions({
    this.canEdit = false,
    this.canVoid = false,
    this.canWithdraw = false,
    this.canDecide = false,
    this.ownDecisionBlocked = false,
  });

  /// "Düzenle": finans yöneticisi her masrafta; diğerleri yalnızca kendi
  /// girdiği, onay bekleyen ya da reddedilen masrafta.
  final bool canEdit;

  /// "İptal Et" (gerekçeli): yalnızca finans yöneticisi.
  final bool canVoid;

  /// "Geri Çek": finans yöneticisi olmayan kişi, kendi bekleyen/reddedilen
  /// masrafında.
  final bool canWithdraw;

  /// "Onayla" / "Reddet": onay izni (katı) + bekleyen masraf + kendi masrafı
  /// değil (Sahip hariç -- üstünde onaylayacak kimse yok).
  final bool canDecide;

  /// Onaylayıcı ama masrafı kendisi girdi (Sahip değil): düğmeler yerine
  /// nedenini söyleyen kısa not.
  final bool ownDecisionBlocked;
}

/// [open]: proje açık mı (tamamlanmış/iptal projede finans hareketi yok).
ExpenseActions expenseActionsFor(User? user, Expense e, {required bool open}) {
  final live = open && !e.isVoided;
  // `can` mevcut finans düğmeleriyle aynı (fail-open) kuralı izler; onay
  // düğmeleri bugünkü gibi KATI `canAccess` ile.
  final manage = user.can(kExpenseFinanceManagePermission);
  final own = e.isCreatedBy(user?.id);
  final ownEditable = own && !e.isApproved && user.can(kExpenseCreatePermission);
  final decidable = live && e.isPending && user.canAccess(kExpenseApprovePermission);
  final isOwner = user?.organizationRoleCode == 'owner';
  return ExpenseActions(
    canEdit: live && (manage || ownEditable),
    canVoid: live && manage,
    canWithdraw: live && !manage && ownEditable,
    canDecide: decidable && (!own || isOwner),
    ownDecisionBlocked: decidable && own && !isOwner,
  );
}

/// Onaylayıcının kendi masrafındaki not (bütçe revizyonundaki notla aynı dil).
const kExpenseOwnDecisionText = 'Bu masrafı sen girdin; başka bir yöneticinin onaylaması gerekir.';
