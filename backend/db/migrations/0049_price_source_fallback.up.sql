-- Fiyat kaynağı sitesi çöktüğünde son bilinen listeyle devam.
--
-- Sahada (2026-10) Ulaş'ın flist.asp sayfası HTTP 500 dönüyordu; senkron
-- her denemede "failed" kaydediyor, hiç başarılı senkron yapmamış firmanın
-- kataloğu boş kalıyordu. Artık sıra: canlı site -> Wayback Machine'deki
-- son kopya -> bu tabloda saklanan son başarılı liste. Bkz.
-- service.priceFallbackFetcher.

-- Listenin VERİ tarihi. last_synced_at senkronun ne zaman yapıldığıdır;
-- arşivden uygulanan Haziran listesi bugün senkronlansa da verisi
-- Haziran'dır. Yedek (arşiv/kayıtlı) bir liste yalnızca bu tarihten
-- YENİYSE uygulanır -- yoksa canlıdan alınmış daha yeni fiyatlar eski
-- listeyle geri alınırdı. Mevcut satırlar için en iyi tahmin: senkron anı.
ALTER TABLE organization_price_sources ADD COLUMN last_list_as_of timestamptz;
UPDATE organization_price_sources SET last_list_as_of = last_synced_at WHERE last_synced_at IS NOT NULL;

-- Kaynak başına SON BAŞARILI liste (canlıdan ya da arşivden). Tedarikçinin
-- herkese açık fiyat listesidir, firmaya ait veri DEĞİLDİR -- bu yüzden
-- organization_id yoktur (bütün firmalar aynı listeyi indirir). Sunucu
-- yeniden başlasa da kaybolmaz; yalnızca daha YENİ tarihli bir listeyle
-- değiştirilir (bkz. UpsertPriceSourceSnapshot).
CREATE TABLE price_source_snapshots (
    source     varchar(30) PRIMARY KEY,
    origin     varchar(20) NOT NULL CHECK (origin IN ('live', 'archive')),
    as_of      timestamptz NOT NULL,
    label      text        NOT NULL DEFAULT '',
    items      jsonb       NOT NULL,
    item_count int         NOT NULL CHECK (item_count > 0),
    saved_at   timestamptz NOT NULL DEFAULT now()
);
