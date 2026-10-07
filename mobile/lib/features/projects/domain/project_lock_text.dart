/// Tamamlanmış ya da iptal edilmiş projenin kilit notu -- proje altındaki
/// TÜM modüller (Sözleşme, Ek İşler, Ödeme Planı, Faturalar, masraf/
/// tahsilat, Taşeron Ödemeleri, Maliyet Kontrolü, Planlama, Ekip) aynı
/// cümleyi gösterir; ekrandan ekrana farklı üç ayrı metin kalmasın.
/// Backend kuralı: `requireOpenProject` (409 "proje kilitli").
const kProjectLockedNoticeText =
    'Proje tamamlandı veya iptal edildi; yeni kayıt eklenemez ve mevcut kayıtlar değiştirilemez. '
    'Geçmiş kayıtlar görüntülenebilir.';

/// Tamamlanmış/iptal edilmiş proje (backend `requireOpenProject`).
bool isProjectClosed(String status) => status == 'completed' || status == 'cancelled';

/// Dökümanlar ve Görevler için daha dar kilit cümleleri: backend bu iki
/// modülde yalnızca YENİ kaydı (yükleme / görev oluşturma) reddeder;
/// fotoğraf/dosya silme, görevi tamamlama ve not ekleme kapalı projede de
/// çalışır -- genel cümle ("mevcut kayıtlar değiştirilemez") burada yanlış
/// olurdu.
const kProjectUploadsLockedText =
    'Proje tamamlandı veya iptal edildi; yeni fotoğraf ve dosya yüklenemez. Mevcut kayıtlar görüntülenebilir.';
const kProjectTasksLockedText =
    'Proje tamamlandı veya iptal edildi; yeni görev eklenemez. Mevcut görevler görüntülenebilir ve tamamlanabilir.';
