# ARVEND Production Deployment Planı — `szutech2` (Linux)

Durum: `f94619c` (metraj) + `ef3d7a6` (production-readiness) local `main`'de ve `origin/main`'de. Bu plan HENÜZ UYGULANMADI. Cloudflare yapılandırmasına (`cloudflared-arvend.service`, tünel ingress) hiçbir adımda dokunulmaz — yalnızca §1'de okunur.

Hedef topoloji:
```
app.arvendyapi.com.tr → Cloudflare Tunnel (szutech2, cloudflared-arvend.service, origin 127.0.0.1:8088)
  → Gateway 127.0.0.1:8088   (YALNIZ loopback)
      ├── /api/*  → 127.0.0.1:8080  (Go API; path rewrite YOK, backend zaten /api/v1 altında)
      └── /*      → 127.0.0.1:3000  (Next.js)
```

## 0. Varsayımlar (§1 ile sunucuda doğrulanacak)
- systemd tabanlı Linux (Ubuntu/Debian), `x86_64`.
- `cloudflared-arvend.service` aktif; ingress `app.arvendyapi.com.tr → http://127.0.0.1:8088`, `originRequest.httpHostHeader` override'ı YOK (Next Server Actions CSRF kontrolü `Host`/`X-Forwarded-Host` ile `Origin`'i karşılaştırır; Host yeniden yazılırsa "Invalid Server Actions request" olur).
- PostgreSQL ≥ 13 (pgcrypto "trusted extension"), yerel veya erişilebilir.
- Dizin düzeni: kaynak `/opt/arvend/src`, binary `/opt/arvend/bin`, upload `/var/lib/arvend/uploads`, env `/etc/arvend/*.env`, sistem kullanıcısı `arvend` (HOME `/opt/arvend`).
- Go 1.26.2 (go.mod), Node 22 LTS (Next 16.3.5, min 20.9), golang-migrate CLI, Caddy 2.x (mevcut gateway yoksa).
- Repo private → sunucuda read-only deploy key ile SSH clone (§3).

## 1. Pre-flight (read-only, hiçbir şeyi değiştirmez)
```bash
head -3 /etc/os-release; uname -m
systemctl status cloudflared-arvend.service --no-pager | head -5
systemctl cat cloudflared-arvend.service | grep -E 'ExecStart|config'
# Config dosyası varsa: ingress'te app.arvendyapi.com.tr -> http://127.0.0.1:8088 ve httpHostHeader YOK olmalı;
# aynı tünelde başka hostname varsa not al (dokunulmayacak). `cloudflared service install <token>` ile kurulduysa
# config.yml YOKTUR — ingress Zero Trust panelindedir, orada kontrol et.
sudo cat /etc/cloudflared/config.yml 2>/dev/null || echo "config.yml yok (token ile kurulmuş olabilir)"
systemctl list-units --type=service --state=running | grep -Ei 'nginx|caddy|apache|traefik|haproxy' || echo "mevcut gateway yok"
sudo ss -tlnp | grep -E ':(8088|8080|3000|5432)\b' || echo "8088/8080/3000 boş"
which go node npm migrate caddy nginx psql; go version 2>/dev/null; node -v 2>/dev/null
id arvend 2>/dev/null || echo "arvend kullanıcısı yok"
sudo ufw status 2>/dev/null || sudo nft list ruleset 2>/dev/null | head -20
```
Karar noktaları:
- 8088/8080/3000'den biri doluysa: 8088 doluysa Caddy bind edemez (eski servisi belirle); 8080/3000 doluysa `PORT`/`-p` ve gateway upstream'leri değişir.
- Nginx/Caddy zaten çalışıyorsa §8b/§8c "mevcut gateway'e ekleme" varyantı kullanılır; mevcut site bloklarına dokunulmaz.

## 2. Sunucu hazırlığı (bir kez)
```bash
sudo useradd --system --user-group --home /opt/arvend --shell /usr/sbin/nologin arvend
sudo mkdir -p /opt/arvend/bin /opt/arvend/src /var/lib/arvend/uploads /etc/arvend
sudo chown -R arvend:arvend /opt/arvend /var/lib/arvend
sudo chmod 750 /var/lib/arvend/uploads
```
Araçlar (yoksa):
- Go 1.26.2: `https://go.dev/dl/go1.26.2.linux-amd64.tar.gz` → `/usr/local/go`, PATH'e `/usr/local/go/bin`.
- Node 22 LTS: NodeSource veya distro paketi; `node -v` ≥ 20.9. `which node` mutlak yolunu not al (§7 unit'te kullanılacak).
- golang-migrate: GitHub release `migrate.linux-amd64.tar.gz` → `/usr/local/bin/migrate`.
- Caddy (yalnız mevcut gateway yoksa): resmi Cloudsmith apt deposu (`caddy` paketi kurulumda `caddy.service`'i stok `:80 file_server` Caddyfile ile BAŞLATIR — §8a'da Caddyfile tamamen değiştirilip reload edilir).

## 3. Kaynak kod (private repo → read-only deploy key)
```bash
sudo -u arvend -H mkdir -m 700 /opt/arvend/.ssh
sudo -u arvend -H ssh-keygen -t ed25519 -N '' -f /opt/arvend/.ssh/id_ed25519 -C arvend@szutech2
sudo cat /opt/arvend/.ssh/id_ed25519.pub     # → GitHub: Savanooo/ARVEND → Settings → Deploy keys → read-only olarak ekle
sudo -u arvend -H bash -c 'ssh-keyscan github.com >> /opt/arvend/.ssh/known_hosts'
cd /opt/arvend && sudo -u arvend -H git clone git@github.com:Savanooo/ARVEND.git /opt/arvend/src
cd /opt/arvend/src && sudo -u arvend -H git checkout ef3d7a6
```
(`cd /opt/arvend` önce: `sudo -u arvend` ile arvend'in giremediği bir cwd'den git çalıştırmak "Unable to read current working directory" hatası verir.)

## 4. Env dosyaları
Sırlar terminale yapıştırılmaz, doğrudan dosyaya üretilir. DB parolası URL içinde geçeceği için `hex` (URL-güvenli):
```bash
DBPW=$(openssl rand -hex 24); echo "DB parolası: $DBPW"   # §5'te psql \password'a girilecek, sonra unut
sudo tee /etc/arvend/backend.env >/dev/null <<EOF
LISTEN_ADDR=127.0.0.1:8080
PORT=8080
CORS_ORIGINS=https://app.arvendyapi.com.tr
DB_URL="postgres://arvend:${DBPW}@127.0.0.1:5432/arvend?sslmode=disable"
JWT_SECRET="$(openssl rand -base64 48)"
COOKIE_DOMAIN=
COOKIE_SECURE=true
SEED_ADMIN_USERNAME=admin
SEED_ADMIN_PASSWORD="<ilk giriş için güçlü geçici parola>"
SEED_ADMIN_FULLNAME="Yönetici"
SETTINGS_ENCRYPTION_KEY="$(openssl rand -base64 32)"
FRONTEND_URL=https://app.arvendyapi.com.tr
STORAGE_ROOT=/var/lib/arvend/uploads
EOF
unset DBPW

sudo tee /etc/arvend/frontend.env >/dev/null <<'EOF'
NEXT_PUBLIC_API_URL=https://app.arvendyapi.com.tr
INTERNAL_API_URL=http://127.0.0.1:8080
NEXT_TELEMETRY_DISABLED=1
EOF

sudo chown root:arvend /etc/arvend/*.env && sudo chmod 640 /etc/arvend/*.env
```
Notlar:
- Değerler çift tırnaklı: dosya hem systemd hem bash (`set -a; . file`) tarafından okunur; `$ # boşluk` içeren parolalar tırnaksız bash'i bozar.
- `LISTEN_ADDR=127.0.0.1:8080` → API yalnız loopback'te dinler (`LISTEN_ADDR` verilmezse `":"+PORT` ile tüm arayüzler — yerel geliştirme davranışı). `CORS_ORIGINS` aynı-origin gateway'de devreye girmez; hijyen için public origin verildi (varsayılanı `http://localhost:3000`).
- `COOKIE_DOMAIN=` boş → host-only cookie (tercih). `SETTINGS_ENCRYPTION_KEY` zorunlu (boot'ta fatal); artık `backend/.env.example`'da belgeli. `godotenv.Load()` .env yoksa sessizce geçer; systemd `EnvironmentFile` yeterli (root olarak, privilege drop'tan önce okunur → 640 sorun değil).
- KRİTİK: `NEXT_PUBLIC_API_URL` build zamanında bundle'a gömülür → `npm run build` bu env ile çalıştırılmalı (§7). `INTERNAL_API_URL` runtime'da her çağrıda okunur.
- Operatör root değilse `/etc/arvend/*.env`'i kendi shell'inde source EDEMEZ (640). Env gerektiren tüm komutlar bu yüzden `sudo -u arvend -H bash -c '...'` sarmalıyla, tek seferlik alt-shell'de çalıştırılır (sırlar etkileşimli shell'e sızmaz).

## 5. Veritabanı + migration
```bash
sudo -u postgres psql -c "CREATE ROLE arvend LOGIN;"
sudo -u postgres psql -c '\password arvend'      # §4'teki DB parolasını gir (SCRAM hash gönderilir; parola shell history/pg log'a düşmez)
sudo -u postgres psql -c "CREATE DATABASE arvend OWNER arvend;"
sudo -u postgres psql -d arvend -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"   # 0001 de IF NOT EXISTS ister; superuser'la önceden kurmak güvenli

sudo -u arvend -H bash -c 'set -a; . /etc/arvend/backend.env; set +a;
  migrate -path /opt/arvend/src/backend/db/migrations -database "$DB_URL" up &&
  migrate -path /opt/arvend/src/backend/db/migrations -database "$DB_URL" version'   # beklenen: 29
```
Migration 0009 varsayılan organizasyonu (`00000000-0000-0000-0000-000000000001`, "Arvend Yapı") ekler; API ilk boot'ta bu org'da kullanıcı yoksa `SEED_ADMIN_*` ile ilk admini oluşturur.

## 6. Backend build + systemd
```bash
cd /opt/arvend/src/backend
sudo -u arvend -H env PATH=$PATH:/usr/local/go/bin CGO_ENABLED=0 \
  go build -trimpath -ldflags="-s -w" -o /opt/arvend/bin/arvend-api ./cmd/api
sudo -u arvend -H env PATH=$PATH:/usr/local/go/bin CGO_ENABLED=0 \
  go build -trimpath -o /opt/arvend/bin/arvend-import-calc-recipes ./cmd/import-calc-recipes
```
`/etc/systemd/system/arvend-api.service`:
```ini
[Unit]
Description=ARVEND API (Go)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=arvend
Group=arvend
WorkingDirectory=/opt/arvend/src/backend
EnvironmentFile=/etc/arvend/backend.env
ExecStart=/opt/arvend/bin/arvend-api
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/arvend/uploads
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
```
(`ProtectHome=true` yalnız `/home`, `/root`, `/run/user`'ı gizler; `/opt/arvend` etkilenmez. Go'nun yazdığı tek yer `STORAGE_ROOT`; multipart geçici dosyaları `PrivateTmp` ile karşılanır. Uzak DB'de `postgresql.service` yoksa `After=` sessizce yok sayılır.)

## 7. Frontend build + systemd
```bash
cd /opt/arvend/src/frontend
sudo -u arvend -H bash -c 'set -a; . /etc/arvend/frontend.env; set +a; npm ci && npm run build'
test -d /opt/arvend/src/frontend/.next/cache || sudo -u arvend mkdir -p /opt/arvend/src/frontend/.next/cache
```
(`sharp` ve tüm `*-linux-x64` native paketleri lockfile'da → `npm ci` Linux x86_64'te tam. `next/image` (Logo) runtime'da `.next/cache/images`'a yazar; `ReadWritePaths` hedefi `-` öneki olmadan verildiği için start anında var olmalı — build sonrası zaten oluşur, guard yine de ekli.)

`/etc/systemd/system/arvend-web.service` (`/usr/bin/node` yolunu `which node` ile doğrula):
```ini
[Unit]
Description=ARVEND Frontend (Next.js)
After=network-online.target arvend-api.service
Wants=network-online.target

[Service]
Type=simple
User=arvend
Group=arvend
WorkingDirectory=/opt/arvend/src/frontend
EnvironmentFile=/etc/arvend/frontend.env
Environment=NODE_ENV=production
ExecStart=/usr/bin/node node_modules/next/dist/bin/next start -H 127.0.0.1 -p 3000 --keepAliveTimeout 125000
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/arvend/src/frontend/.next/cache
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
```
`--keepAliveTimeout 125000`: Node'un varsayılan 5 sn keep-alive'ı, Caddy'nin 2 dk upstream keep-alive'ından kısa olduğu için Caddy kapanmış bağlantıyı yeniden kullanır → POST'larda ara sıra 502. Upstream'in idle süresi proxy'ninkinden UZUN olmalı; 125 sn > 120 sn.

## 8. Gateway — 127.0.0.1:8088

Caddy'de site adresindeki host kısmı **bind adresi değil, Host-header matcher'ıdır**. `http://127.0.0.1:8088 { }` yazılırsa (a) Caddy TÜM arayüzlerde dinler, (b) cloudflared `Host: app.arvendyapi.com.tr` gönderdiği için hiçbir site eşleşmez ve her istek boş 200 alır (`caddy validate` bunu yakalamaz). Doğru form: port-only adres + `bind 127.0.0.1`.

### 8a. Caddy (mevcut gateway yoksa — önerilen)
`/etc/caddy/Caddyfile` (stok dosyanın yerine, tamamı):
```
{
	servers 127.0.0.1:8088 {
		trusted_proxies static 127.0.0.1/32
	}
}

:8088 {
	bind 127.0.0.1

	@api path /api/*
	request_body @api {
		max_size 30MiB
	}

	handle @api {
		reverse_proxy 127.0.0.1:8080 {
			header_up X-Forwarded-Proto https
			flush_interval -1
			transport http {
				keepalive 90s
			}
		}
	}

	handle {
		reverse_proxy 127.0.0.1:3000 {
			header_up X-Forwarded-Proto https
		}
	}
}
```
- `:8088` + `bind 127.0.0.1` → dinleyici `127.0.0.1:8088`, hostname yok → otomatik HTTPS yok, her Host kabul (TLS Cloudflare kenarında biter).
- `/api/*` path'i olduğu gibi 8080'e gider (rewrite yok).
- `request_body @api max_size 30MiB`: backend JSON uçlarında global gövde sınırı yok → gateway sınırı; app'in 25 MiB + 1 KiB `MaxBytesReader`'ının üstünde multipart payı için yeterli.
- `flush_interval -1`: 25 MiB indirme yanıtlarını buffer'lamadan akıtır (istek gövdeleri zaten akıtılır).
- `header_up X-Forwarded-Proto https`: tünel origin'e düz HTTP ile gelir; Next `request.nextUrl.protocol` ve gelecekteki mutlak-URL mantığı için doğru şema. (Not: `proxy.ts` redirect'leri Next tarafından göreli `Location: /giris` olarak gönderilir — header olmasa da çalışır; yine de doğru sinyal.)
- `transport http keepalive 90s`: Go `IdleTimeout=120s` ile Caddy'nin varsayılan 2 dk upstream keep-alive'ı eşit → "sunucu kapatırken proxy yeniden kullanır" yarışı; 90 sn bunu önler. Next tarafı için §7'deki `--keepAliveTimeout`.
- `servers 127.0.0.1:8088 { trusted_proxies }`: yalnızca bu dinleyiciye özgü; cloudflared'ın `X-Forwarded-For`'u korunur → chi `RealIP` gerçek istemci IP'sini loglar. Global blok başka siteleri etkilemez.
- Caddy varsayılan sunucu timeout'ları sınırsız → backend'in 5 dk'sı belirleyici. `admin off` EKLENMEZ: `systemctl reload caddy` admin API'yi (`localhost:2019`, loopback) kullanır.
```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl enable caddy
sudo systemctl reload caddy || sudo systemctl restart caddy   # paket kurulumda zaten başlatmıştır; `enable --now` no-op olur, reload ŞART
```

### 8b. Caddy zaten kurulu ve başka siteler tarafından kullanılıyorsa
Yukarıdaki `:8088 { ... }` bloğunu `/etc/caddy/sites/arvend.caddy`'ye koy; ana Caddyfile'a yalnızca tek satır ekle: `import /etc/caddy/sites/*.caddy`. Global bloğa `servers 127.0.0.1:8088 { trusted_proxies static 127.0.0.1/32 }` eklenebilir — adresle kapsamlı olduğu için diğer siteleri etkilemez. Mevcut site bloklarına dokunma. `caddy validate` → `systemctl reload caddy`.

### 8c. Nginx zaten kurulu ve kullanılıyorsa (alternatif)
`/etc/nginx/sites-available/arvend.conf` → `sites-enabled`'a symlink:
```nginx
server {
    listen 127.0.0.1:8088;
    server_name app.arvendyapi.com.tr;

    location /api/ {
        client_max_body_size 30m;
        proxy_pass http://127.0.0.1:8080;      # SONUNA / KOYMA: /api/ prefix'i korunmalı
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```
`X-Real-IP` EKLEME: chi `RealIP` onu `X-Forwarded-For`'a tercih eder ve 127.0.0.1 loglanır. Upstream keepalive bloğu yok → bağlantı başına `Connection: close`, keep-alive yarışı yok.
```bash
sudo nginx -t && sudo systemctl reload nginx
```

## 9. Başlatma sırası + doğrulama
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now arvend-api
curl -s -w ' [%{http_code}]\n' http://127.0.0.1:8080/healthz                         # {"status":"ok"} [200] => API canlı (kimlik doğrulamasız, DB'ye bakmaz)
sudo journalctl -u arvend-api -n 20 --no-pager                                      # "ARVEND API 127.0.0.1:8080 adresinde dinliyor", "İlk admin kullanıcı oluşturuldu"

sudo systemctl enable --now arvend-web
curl -s http://127.0.0.1:3000/giris | grep -q '<html' && echo "web OK"

# gateway (§8) devreye alındıktan sonra:
sudo ss -tlnp | grep -E ':(8088|8080|3000)\b'
#   127.0.0.1:8088 (caddy)        ← *:8088 / 0.0.0.0:8088 OLMAMALI
#   127.0.0.1:8080 (arvend-api)   ← LISTEN_ADDR sayesinde yalnız loopback; *:8080 görülürse env eksik
#   127.0.0.1:3000 (node)
curl -s -w '\n%{http_code}\n' -H 'Host: app.arvendyapi.com.tr' http://127.0.0.1:8088/api/v1/auth/me   # 401 (yalnız Go 401 döndürür; Next'te /api yok)
curl -s -H 'Host: app.arvendyapi.com.tr' http://127.0.0.1:8088/giris | grep -q '<html' && echo "gateway→web OK"   # status-only kontrol yanıltır
curl -sI -H 'Host: app.arvendyapi.com.tr' http://127.0.0.1:8088/admin | grep -Ei '^(HTTP|location)'   # 307 + location: /giris (göreli)

# public (Cloudflare'a dokunmadan; tünel zaten 8088'e bakıyor):
curl -sI https://app.arvendyapi.com.tr/giris | head -1                              # HTTP/2 200
curl -s -w '\n%{http_code}\n' https://app.arvendyapi.com.tr/api/v1/auth/me          # 401
```
Tarayıcı: `https://app.arvendyapi.com.tr/giris` → admin ile giriş → DevTools'ta `Set-Cookie: access_token=...; Path=/; Max-Age=900; HttpOnly; Secure; SameSite=Strict` (Domain yok = host-only). `/teklifler` SSR sayfası açılmalı (INTERNAL_API_URL → loopback). Bir proje dosyası yükle/indir (≤25 MiB) — eski 10 sn sınırı artık yok.

Girişten hemen sonra:
```bash
# 1) UI'da admin parolasını değiştir; 2) bootstrap parolasını env'den sil (kullanıcı varken seed bir daha çalışmaz, restart gerekmez):
sudo sed -i '/^SEED_ADMIN_/d' /etc/arvend/backend.env
```

## 10. İlk veri (sunucu boot'ta asla seed etmez — kontrollü provisioning)
1. Ürün kataloğu eski sistemden taşınacaksa ÖNCE: `SOURCE_MONGO_URI=... SOURCE_MONGO_DB=... DB_URL=... go run ./cmd/migrate-products` (opsiyonel, ayrı karar).
2. Metraj reçeteleri (idempotent, var olanı asla ezmez):
```bash
sudo -u arvend -H bash -c 'cd /opt/arvend/src/backend && set -a && . /etc/arvend/backend.env && set +a &&
  exec /opt/arvend/bin/arvend-import-calc-recipes \
    -fixture db/fixtures/byz_calc_recipes.json \
    -org 00000000-0000-0000-0000-000000000001 \
    -link-products'
```
`-link-products`: ad+birim eşleşen ürün varsa bağlar, yoksa oluşturur → adım 1 çalıştırılmadıysa yeni "Hesaplama Malzemesi" ürünleri oluşacaktır (bilinçli karar).
3. Ek firma: `go run ./cmd/seed-organization -name ... -slug ... -admin-username ... -admin-password ...`

## 11. Rollback
İlk production kurulumunda "önceki sürüm" yoktur: rollback = `systemctl stop arvend-web arvend-api` (+ şema gidecekse `migrate ... drop -f` veya DB drop). Sonraki sürümler için:
```bash
sudo systemctl stop arvend-web arvend-api
# ÖNCE migrate (down dosyaları yalnız YENİ checkout'ta var), SONRA git checkout. Sayı saymak yerine hedef sürüm:
sudo -u arvend -H bash -c 'set -a; . /etc/arvend/backend.env; set +a;
  migrate -path /opt/arvend/src/backend/db/migrations -database "$DB_URL" goto 27'   # ef3d7a6 → e5aa560 için (0028+0029 geri alınır)
cd /opt/arvend/src && sudo -u arvend -H git checkout e5aa560   # §6-7 rebuild; start
```
0028/0029 down migration'ları doğrulandı (up/down/up). Gateway/Cloudflare rollback gerektirmez.

## 12. Bilinen açık noktalar (bu planın kapsamı dışında, ayrı karar)
Kapatıldı (`chore(production): harden auth refresh and loopback binding`): tarayıcı içi 401→tek-uçuş refresh→retry (`lib/api.ts` `fetchWithSession`), `LISTEN_ADDR` ile loopback bind, `CORS_ORIGINS` env, `/healthz`, `.env.example` eksikleri.

Kalanlar:
- **RSC tarafında oturum yenileme yok (bilinçli):** süresi dolmuş access token'la gelen bir sayfa navigasyonu (RSC isteği) 401 alır ve layout `/giris`'e yönlendirir; yalnızca sayfa içi `apiClient` istekleri sessizce yenilenir. Sebep: backend refresh token'ı rotasyonla tek kullanımlık verir ve Server Component yanıta Set-Cookie yazamaz — RSC'de refresh yapılsa tarayıcıdaki refresh token iptal olur. Kalıcı çözüm `proxy.ts` seviyesinde (yanıta cookie yazabilir) refresh + süreç içi tek-uçuş + tüm yetkili route'ları kapsayan matcher; bununla birlikte istemci refresh'i ile yarışabileceği için önce backend'e kısa bir "yeniden kullanım tolerans penceresi" (grace window) eklenmesi önerilir.
- **Çok sekmeli rotasyon yarışı:** iki sekme aynı anda refresh yaparsa ikincisi 401 alır ve backend `clearSessionCookies` ile ortak cookie kavanozunu siler → her iki sekme de düşer. Tek-uçuş yalnızca sekme içinde korur. Backend'de grace window ya da başarısız refresh'te cookie silmemek (auth iş mantığı, dokunulmadı) bunu çözer.
- JSON uçlarında uygulama-seviyesi gövde sınırı yok → gateway `30MiB` ile telafi (Caddy limit aşımında bağlantıyı keser, Nginx temiz 413 döner).
- Firewall yine de 8080/3000'i dışarıya kapatmalı (defense in depth); `LISTEN_ADDR` unutulursa `ss -tlnp` §9'da `*:8080` gösterir.
