-- GÜVENLİ GERİ ALMA SINIRI: bu down migration, yalnızca hiçbir iki
-- organizasyonun aynı offer_no değerine sahip olmadığı bir veritabanında
-- çalışır (ör. tek organizasyonlu temiz bir geliştirme ortamında, up'tan
-- hemen sonra geri alınıyorsa). Birden fazla organizasyon gerçek veri
-- biriktirdikten sonra (her biri kendi TKF-2026-0001'ini bağımsız
-- ürettiğinden) bu ALTER, "duplicate key" hatasıyla başarısız olur --
-- bu beklenen ve kabul edilebilir bir sınırdır: iki farklı firmanın aynı
-- offer_no'ya sahip olduğu bir durumu veri kaybı olmadan global UNIQUE'e
-- geri döndürmenin matematiksel bir yolu yoktur. Böyle bir durumda migrate
-- "dirty" işaretler; şema aslında bozulmamıştır (Postgres DDL
-- transactional'dır) -- `migrate force <önceki versiyon>` ile
-- schema_migrations bookkeeping'i düzeltip devam edin.
ALTER TABLE offers DROP CONSTRAINT offers_organization_id_offer_no_key;
ALTER TABLE offers ADD CONSTRAINT offers_offer_no_key UNIQUE (offer_no);
