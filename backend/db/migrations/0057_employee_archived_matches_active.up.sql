-- Personelde archived_at ile is_active ayrışmıştı: "Pasifleştir" ikisini
-- birlikte yazıyordu ama formdan yeniden "Aktif" yapılan personelde
-- archived_at temizlenmiyor, "Aktif" işareti kaldırılınca da hiç
-- dolmuyordu. Ana sayfa (dashboard) archived_at'e baktığı için yeniden
-- aktifleşen personel orada eksik sayılıyordu. Kod artık ikisini birlikte
-- tutuyor (UpdateEmployee); bu migration mevcut satırları hizalar.
--
-- Aktif ama arşivli -> arşiv kaldırılır (personel çalışıyor).
UPDATE employees SET archived_at = NULL
WHERE is_active AND archived_at IS NOT NULL;

-- Pasif ama arşivsiz -> arşiv zamanı olarak satırın son değişikliği
-- (pasife alındığı an en iyi tahmini; gerçek an hiçbir yerde tutulmadı).
UPDATE employees SET archived_at = updated_at
WHERE NOT is_active AND archived_at IS NULL;
