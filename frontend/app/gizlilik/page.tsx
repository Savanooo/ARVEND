import type { Metadata } from "next";

import { Logo } from "@/components/layout/Logo";

/*
 * Gizlilik Politikası + KVKK aydınlatma metni. Google Play ve App Store
 * gönderimi için herkese açık, giriş istemeyen bir URL şart
 * (https://app.arvendyapi.com.tr/gizlilik); bu yüzden proxy.ts matcher'ında
 * YOK. "#hesap-silme" bölümü Play'in hesap silme URL'si olarak da verilir.
 *
 * İçerik uygulamanın gerçekte yaptığına dayanır (mobile/RELEASE.md §10 veri
 * envanteri): reklam/analitik SDK'sı, konum, rehber, mikrofon yok. Yeni bir
 * veri türü (ör. push bildirimi cihaz kimliği) eklenirse burası ve Play'deki
 * Veri güvenliği formu birlikte güncellenir.
 */

const YAYINCI = "ARVEND Yapı";
// Boşsa adres satırı gösterilmez.
const ADRES = "Şerefiye Mahallesi, Kıbrıs Sokak No: 29 D: 3, Merkez / Düzce";
const EPOSTA = "info@arvendyapi.com.tr";
const SON_GUNCELLEME = "6 Ekim 2026";

export const metadata: Metadata = {
  title: "Gizlilik Politikası · ARVEND",
  description: "ARVEND uygulamasının kişisel verileri nasıl işlediği ve KVKK kapsamındaki haklarınız.",
};

function Section({ id, title, children }: { id?: string; title: string; children: React.ReactNode }) {
  return (
    <section id={id} className="scroll-mt-6">
      <h2 className="mb-3 text-lg font-semibold text-text">{title}</h2>
      <div className="flex flex-col gap-3 leading-relaxed text-text">{children}</div>
    </section>
  );
}

function List({ items }: { items: React.ReactNode[] }) {
  return (
    <ul className="list-disc space-y-1.5 pl-5">
      {items.map((it, i) => (
        <li key={i}>{it}</li>
      ))}
    </ul>
  );
}

export default function GizlilikPage() {
  const mail = (
    <a href={`mailto:${EPOSTA}`} className="font-medium text-gold underline underline-offset-2">
      {EPOSTA}
    </a>
  );

  return (
    <main className="mx-auto flex max-w-3xl flex-col gap-8 px-4 py-10 sm:px-6">
      <header className="flex flex-col gap-4 border-b border-border pb-6">
        <Logo />
        <div>
          <h1 className="text-2xl font-semibold text-text">Gizlilik Politikası ve KVKK Aydınlatma Metni</h1>
          <p className="mt-1 text-sm text-text-muted">Son güncelleme: {SON_GUNCELLEME}</p>
        </div>
        <p className="leading-relaxed">
          Bu metin, ARVEND web uygulamasının (app.arvendyapi.com.tr) ve ARVEND mobil uygulamasının kişisel
          verileri nasıl işlediğini, 6698 sayılı Kişisel Verilerin Korunması Kanunu (KVKK) kapsamındaki
          haklarınızı ve hesabınızı nasıl sildirebileceğinizi açıklar.
        </p>
      </header>

      <Section title="1. Biz kimiz">
        <p>
          ARVEND, inşaat ve tadilat firmalarının projelerini, tekliflerini, şantiye işlerini ve personelini
          yönettiği bir iş uygulamasıdır. Uygulamayı işleten:
        </p>
        <p className="rounded-md border border-border bg-surface px-4 py-3">
          <strong>{YAYINCI}</strong>
          {ADRES && (
            <>
              <br />
              {ADRES}
            </>
          )}
          <br />
          E-posta: {mail}
        </p>
        <p>
          Uygulamayı kullanan her firma, kendi müşteri, personel ve proje kayıtları bakımından veri
          sorumlusudur; ARVEND bu kayıtları o firma adına ve onun talimatıyla işler. Kullanıcı hesapları ve
          uygulamanın işletilmesi bakımından veri sorumlusu {YAYINCI}&apos;dır.
        </p>
      </Section>

      <Section title="2. Hangi verileri işliyoruz">
        <List
          items={[
            <>
              <strong>Hesap bilgileri:</strong> kullanıcı adı, ad soyad, rol ve yetkiler, bağlı olduğunuz firma.
              Şifreniz yalnızca geri döndürülemez şekilde özetlenerek (bcrypt) saklanır; düz hâli hiçbir yerde
              tutulmaz.
            </>,
            <>
              <strong>Firmanın girdiği iş kayıtları:</strong> müşteri adı, telefonu, e-postası, adresi ve vergi
              bilgileri; proje, teklif, sözleşme, tahsilat, masraf ve taşeron kayıtları.
            </>,
            <>
              <strong>Personel kayıtları:</strong> ad soyad, telefon, görev, işe başlama tarihi, ücret, mesai
              kayıtları ve ödemeler. Ücret ve ödeme bilgileri yalnızca yetkili kullanıcılara gösterilir.
            </>,
            <>
              <strong>Fotoğraflar ve dosyalar:</strong> yalnızca sizin çekip ya da seçip projeye yüklediğiniz
              şantiye fotoğrafları ve belgeler.
            </>,
            <>
              <strong>Görev ve proje notları,</strong> uygulama içi bildirimler.
            </>,
            <>
              <strong>Teknik kayıtlar:</strong> oturum bilgileri, kimin hangi kaydı ne zaman değiştirdiğini
              gösteren işlem kayıtları ve sunucu erişim kayıtları (IP adresi, zaman).
            </>,
          ]}
        />
        <p>
          <strong>Toplamadıklarımız:</strong> konumunuz, rehberiniz, mikrofonunuz, reklam kimliğiniz. Uygulamada
          reklam ve üçüncü taraf analitik/izleme aracı yoktur. Kamera izni yalnızca siz fotoğraf çekmek
          istediğinizde kullanılır.
        </p>
      </Section>

      <Section title="3. Neden işliyoruz (amaç ve hukuki sebep)">
        <List
          items={[
            <>
              Uygulamanın size ve firmanıza sunulması, iş kayıtlarının tutulması ve yetkilendirme —{" "}
              <em>sözleşmenin kurulması ve ifası</em> (KVKK m. 5/2-c).
            </>,
            <>
              Hesap güvenliği, kötüye kullanımın önlenmesi ve hataların giderilmesi —{" "}
              <em>meşru menfaat</em> (KVKK m. 5/2-f).
            </>,
            <>
              Mevzuattan doğan saklama ve bildirim yükümlülükleri — <em>hukuki yükümlülük</em> (KVKK m. 5/2-ç).
            </>,
          ]}
        />
        <p>Verilerinizi satmıyoruz ve reklam amacıyla kullanmıyoruz.</p>
      </Section>

      <Section title="4. Kimlerle paylaşıyoruz">
        <List
          items={[
            <>
              <strong>Firmanızdaki yetkili kullanıcılar:</strong> kayıtlar yalnızca aynı firmadaki, rolü buna izin
              veren kişilere gösterilir. Bir firma başka bir firmanın verisini göremez.
            </>,
            <>
              <strong>Altyapı hizmet sağlayıcıları:</strong> uygulamaya güvenli bağlantı Cloudflare, Inc. ağı
              üzerinden sağlanır; bu nedenle trafik yurt dışındaki sunuculardan geçebilir (KVKK m. 9).
            </>,
            <>
              <strong>E-posta:</strong> uygulamadan gönderilen teklif ve ek iş e-postaları, firmanızın ayarlarda
              tanımladığı e-posta sunucusu üzerinden alıcıya iletilir.
            </>,
            <>
              <strong>Yetkili kamu kurumları:</strong> yalnızca yasal bir zorunluluk olduğunda.
            </>,
          ]}
        />
      </Section>

      <Section title="5. Saklama ve güvenlik">
        <p>
          Veriler bizim yönettiğimiz sunucularda saklanır. Uygulama ile sunucu arasındaki bütün trafik şifrelidir
          (HTTPS). Her istek firma ve rol bazında yetki kontrolünden geçer; veritabanı düzenli olarak yedeklenir.
        </p>
        <p>
          Veriler, firmanın hesabı açık olduğu sürece saklanır. Silme talebinden sonra, yasal saklama
          yükümlülükleri saklı kalmak üzere en geç 30 gün içinde silinir ya da anonim hâle getirilir;
          yedeklerden, yedekler dönüşümlü olarak üzerine yazıldıkça kaldırılır.
        </p>
      </Section>

      <Section id="hesap-silme" title="6. Hesabınızı ve verilerinizi silme">
        <p>Hesabınızın ve kişisel verilerinizin silinmesini iki yoldan isteyebilirsiniz:</p>
        <List
          items={[
            <>Firmanızın yöneticisi, uygulamadaki Kullanıcılar ekranından hesabınızı kapatabilir.</>,
            <>
              Ya da {mail} adresine &quot;Hesap silme&quot; konulu bir e-posta gönderin; kullanıcı adınızı ve
              firmanızın adını yazın. Talebiniz en geç 30 gün içinde sonuçlandırılır.
            </>,
          ]}
        />
        <p>
          Hesabınız silindiğinde kullanıcı adınız, ad soyadınız ve hesabınıza bağlı kişisel bilgiler silinir.
          Firmanın iş kayıtları (projeler, teklifler, ödemeler) firmaya ait olduğundan, yalnızca firma
          yöneticisinin talebiyle silinir.
        </p>
      </Section>

      <Section title="7. KVKK kapsamındaki haklarınız">
        <p>KVKK m. 11 uyarınca;</p>
        <List
          items={[
            "kişisel verilerinizin işlenip işlenmediğini öğrenme ve işlenmişse bilgi talep etme,",
            "işlenme amacını ve amacına uygun kullanılıp kullanılmadığını öğrenme,",
            "yurt içinde veya yurt dışında aktarıldığı üçüncü kişileri bilme,",
            "eksik veya yanlış işlenmişse düzeltilmesini, KVKK m. 7 şartlarıyla silinmesini veya yok edilmesini isteme ve bu işlemlerin aktarıldığı kişilere bildirilmesini isteme,",
            "otomatik sistemlerle analiz sonucu aleyhinize bir sonuç çıkmasına itiraz etme,",
            "kanuna aykırı işleme nedeniyle zarara uğramanız hâlinde zararın giderilmesini talep etme",
          ]}
        />
        <p>haklarına sahipsiniz. Başvurularınızı {mail} adresine iletebilirsiniz; en geç 30 gün içinde yanıtlanır.</p>
      </Section>

      <Section title="8. Çocuklar">
        <p>ARVEND bir iş uygulamasıdır ve 18 yaşından küçükler için tasarlanmamıştır.</p>
      </Section>

      <Section title="9. Değişiklikler">
        <p>
          Bu metni güncellediğimizde yukarıdaki &quot;Son güncelleme&quot; tarihi değişir. Önemli değişiklikleri
          uygulama içinden duyururuz.
        </p>
      </Section>
    </main>
  );
}
