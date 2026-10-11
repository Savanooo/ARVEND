"use client";

import { ImageOff } from "lucide-react";
import { useEffect, useRef, useState } from "react";

import { fetchWithSession } from "@/lib/api";

/**
 * Oturum isteyen bir API görselini (ör. şantiye fotoğrafı) gösterir.
 *
 * Neden: <img src={API_BASE + yol}> isteği fetchWithSession'ın oturum
 * yenilemesini atlıyordu -- erişim çerezi ~15 dk sonra dolunca tarayıcı
 * görseli 401 ile alamıyor, küçük resimler kırık görünüyordu (dosya
 * indirmelerindeki düzeltmenin -- 6c6e186 -- aynısı). İçerik burada
 * fetchWithSession ile (401'de oturum yenilenir) blob olarak alınır ve
 * nesne URL'siyle gösterilir; tıklayınca aynı blob yeni sekmede açılır.
 * Görsel, görünür alana yaklaşınca yüklenir; bileşen kalkınca URL bırakılır.
 * Yüklenemezse (ağ kesintisi vb.) kutucuğa tıklamak yeniden dener.
 */
export function SessionImage({
  path,
  alt,
  className = "",
}: {
  // API köküne göre yol (ör. /api/v1/projects/{id}/photos/{photoId}/content).
  path: string;
  alt: string;
  className?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [url, setUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let cancelled = false;
    let objectUrl: string | null = null;

    function load() {
      fetchWithSession(path)
        .then(async (res) => {
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const blob = await res.blob();
          if (cancelled) return;
          objectUrl = URL.createObjectURL(blob);
          setUrl(objectUrl);
        })
        .catch(() => {
          if (!cancelled) setFailed(true);
        });
    }

    let observer: IntersectionObserver | null = null;
    if (typeof IntersectionObserver === "undefined") {
      load();
    } else {
      observer = new IntersectionObserver(
        (entries) => {
          if (!entries.some((e) => e.isIntersecting)) return;
          observer?.disconnect();
          load();
        },
        { rootMargin: "200px" }
      );
      observer.observe(el);
    }
    return () => {
      cancelled = true;
      observer?.disconnect();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [path, attempt]);

  return (
    <div ref={ref} className={className}>
      {url ? (
        <a href={url} target="_blank" rel="noopener" className="block h-full w-full">
          {/* eslint-disable-next-line @next/next/no-img-element -- blob: URL, next/image optimize edemez */}
          <img src={url} alt={alt} className="h-full w-full object-cover" />
        </a>
      ) : failed ? (
        <button
          type="button"
          onClick={() => {
            setFailed(false);
            setAttempt((n) => n + 1);
          }}
          aria-label={`${alt} yüklenemedi, tekrar dene`}
          title="Fotoğraf yüklenemedi — tekrar denemek için tıkla"
          className="flex h-full w-full items-center justify-center bg-surface-hover text-text-muted hover:text-text"
        >
          <ImageOff size={20} strokeWidth={1.5} />
        </button>
      ) : (
        <div aria-hidden className="h-full w-full animate-pulse bg-surface-hover" />
      )}
    </div>
  );
}
