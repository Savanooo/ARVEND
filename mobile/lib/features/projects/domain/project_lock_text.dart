/// Tamamlanmış ya da iptal edilmiş projenin kilit notu -- proje altındaki
/// TÜM modüller (Sözleşme, Ek İşler, Ödeme Planı, Faturalar, masraf/
/// tahsilat, Taşeron Ödemeleri, Maliyet Kontrolü, Planlama, Ekip) aynı
/// cümleyi gösterir; ekrandan ekrana farklı üç ayrı metin kalmasın.
/// Backend kuralı: `requireOpenProject` (409 "proje kilitli").
const kProjectLockedNoticeText =
    'Proje tamamlandı veya iptal edildi; yeni kayıt eklenemez ve mevcut kayıtlar değiştirilemez. '
    'Geçmiş kayıtlar görüntülenebilir.';
