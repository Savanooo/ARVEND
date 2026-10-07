"use client";

import Link from "next/link";
import { useEffect } from "react";

import { buttonClass } from "@/components/ui/styles";

// error.tsx / not-found.tsx dosyalarının ortak görünümü. Bayat bir
// bağlantı (ör. silinmiş bir teklifin bildirimi) ya da beklenmeyen bir
// sunucu hatası Next'in genel "Application error" ekranı yerine, kabuğun
// içinde anlaşılır bir mesaj ve çıkış yolu gösterir.

function Fallback({
  title,
  description,
  children,
}: {
  title: string;
  description: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex flex-1 items-center justify-center p-8">
      <div className="flex max-w-md flex-col items-center gap-3 rounded-lg border border-border bg-surface px-6 py-10 text-center">
        <h1 className="text-base font-semibold text-text">{title}</h1>
        <p className="text-sm text-text-muted">{description}</p>
        <div className="mt-2 flex flex-wrap justify-center gap-2">{children}</div>
      </div>
    </div>
  );
}

export function NotFoundView() {
  return (
    <Fallback
      title="Kayıt bulunamadı"
      description="Aradığınız sayfa ya da kayıt silinmiş, taşınmış veya hiç oluşturulmamış olabilir."
    >
      <Link href="/" className={buttonClass("primary")}>
        Ana Sayfaya Dön
      </Link>
    </Fallback>
  );
}

export function RouteErrorView({ error, retry }: { error: Error & { digest?: string }; retry: () => void }) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <Fallback
      title="Bir şeyler ters gitti"
      description="Sayfa yüklenirken beklenmeyen bir hata oluştu. Tekrar deneyebilir ya da ana sayfaya dönebilirsiniz."
    >
      <button type="button" onClick={() => retry()} className={buttonClass("primary")}>
        Tekrar Dene
      </button>
      <Link href="/" className={buttonClass("secondary")}>
        Ana Sayfa
      </Link>
      {error.digest && <p className="basis-full text-xs text-text-muted">Hata kodu: {error.digest}</p>}
    </Fallback>
  );
}
