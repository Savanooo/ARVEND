// Ödeme planı / fatura ekranlarının mutlak yolları ve izin kodları. Rotalar
// proje detay rotasının (`/projeler/:id`) ALTINA kaydedilir (bkz.
// finance_plan_routes.dart).

/// Okuma izni -- backend `projPerm(PermProjectsFinanceRead)`.
const kFinancePlanReadPermission = 'projects.finance.read';

/// Yazma izni -- backend `projPerm(PermProjectsFinanceManage)`.
const kFinancePlanManagePermission = 'projects.finance.manage';

/// Proje detayındaki Finans grubunun `?grup=` değeri.
const kFinancePlanGroup = 'finans';

/// Finans grubundaki alt görünümlerin `?alt=` değerleri.
const kPaymentPlanAlt = 'odeme-plani';
const kInvoicesAlt = 'faturalar';

String _project(String projectId) => '/projeler/${Uri.encodeComponent(projectId)}';

String paymentPlanPath(String projectId) => '${_project(projectId)}/$kPaymentPlanAlt';

String paymentPlanNewPath(String projectId) => '${paymentPlanPath(projectId)}/yeni';

String paymentPlanItemPath(String projectId, String itemId) =>
    '${paymentPlanPath(projectId)}/${Uri.encodeComponent(itemId)}';

String paymentPlanItemEditPath(String projectId, String itemId) => '${paymentPlanItemPath(projectId, itemId)}/duzenle';

String invoicesPath(String projectId) => '${_project(projectId)}/$kInvoicesAlt';

String invoiceNewPath(String projectId) => '${invoicesPath(projectId)}/yeni';

String invoicePath(String projectId, String invoiceId) =>
    '${invoicesPath(projectId)}/${Uri.encodeComponent(invoiceId)}';
