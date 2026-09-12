# Arvend Yapı — ARVEND

Arvend Yapı ERP sisteminin sıfırdan, modül modül yeniden yazımı (Go +
PostgreSQL + Next.js). Önceki sistem: `byz-app` (Flask + MongoDB).

## Yığın

- **Backend:** Go, [chi](https://github.com/go-chi/chi) router, `pgx` +
  `sqlc`, `golang-migrate`, JWT (httpOnly cookie).
- **Veritabanı:** PostgreSQL.
- **Frontend:** Next.js (App Router) + Tailwind CSS.

## Yerel geliştirme

### Veritabanı

Bu makinede Docker yerine Homebrew PostgreSQL kullanılıyor:

```bash
brew services start postgresql@18   # zaten çalışıyorsa gerekmez
createdb arvend_dev
```

`deploy/docker-compose.yml` Docker kurulu bir makinede/sunucuda alternatif
olarak kullanılabilir.

### Backend

```bash
cd backend
cp .env.example .env        # DB_URL, JWT_SECRET, SEED_ADMIN_* değerlerini doldur
migrate -path db/migrations -database "$DB_URL" up
go run ./cmd/api
```

API varsayılan olarak `:8080` üzerinde, `/api/v1/...` altında yayınlanır.

### Frontend

```bash
cd frontend
npm install
npm run dev
```

`http://localhost:3000/giris`

## Modüller (planlanan sıra)

1. ✅ Auth + Kullanıcı/Rol Yönetimi + Admin Paneli İskeleti
2. Teklif yönetimi
3. Personel / Mesai
4. Maaş
5. Borç / Alacak
6. Proje (masraf / fatura / taşeron)
