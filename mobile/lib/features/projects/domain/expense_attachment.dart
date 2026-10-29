/// Masraf fişi / belgesi (backend migration 0076): masrafa eklenmiş fotoğraf
/// (fiş, fatura) ya da PDF. İçerik ayrı uçtan, kimlik doğrulamalı gelir
/// (`GET {base}/attachments/{id}/content`); bkz. ExpenseAttachmentsRepository.
class ExpenseAttachment {
  const ExpenseAttachment({
    required this.id,
    required this.expenseId,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
    required this.createdAt,
    this.uploadedBy,
  });

  final String id;
  final String expenseId;
  final String originalName;
  final String mimeType;
  final int sizeBytes;
  final String createdAt;
  final String? uploadedBy;

  /// Fotoğraf mı (küçük resim + tam ekran); değilse belge (PDF) -- telefonun
  /// kendi görüntüleyicisiyle açılır.
  bool get isImage => mimeType.startsWith('image/');

  /// HEIC/HEIF'i Flutter her cihazda çözemez; küçük resim yerine simge.
  bool get isDisplayableImage => isImage && mimeType != 'image/heic' && mimeType != 'image/heif';

  /// Telefona yazılırken kullanılan ad (sunucu adı boşsa kimlik).
  String get localName => originalName.trim().isEmpty ? id : originalName.trim();

  factory ExpenseAttachment.fromJson(Map<String, dynamic> json) => ExpenseAttachment(
    id: json['id'] as String,
    expenseId: json['expense_id'] as String? ?? '',
    originalName: json['original_name'] as String? ?? '',
    mimeType: json['mime_type'] as String? ?? '',
    sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    createdAt: json['created_at'] as String? ?? '',
    uploadedBy: json['uploaded_by'] as String?,
  );
}

/// Bir masrafa en fazla bu kadar belge (backend domain.ExpenseAttachmentsMax).
const kExpenseAttachmentsMax = 10;

/// Dosya seçiciden kabul edilen uzantılar -- sunucu türü içerikten ayrıca
/// denetler (JPEG/PNG/WebP/HEIC/PDF); burada yalnızca yanlış dosyayı
/// yüklemeden önce söylemek için.
const kExpenseAttachmentExtensions = {'pdf', 'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'};

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 || dot == name.length - 1 ? '' : name.substring(dot + 1).toLowerCase();
}

bool isAcceptedExpenseAttachmentName(String name) => kExpenseAttachmentExtensions.contains(_extensionOf(name));

/// Seçilen (henüz yüklenmemiş) dosya fotoğraf mı -- küçük resim için.
bool isImageFileName(String name) => const {'jpg', 'jpeg', 'png', 'webp'}.contains(_extensionOf(name));
