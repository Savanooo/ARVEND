import { ChevronLeft, ChevronRight } from "lucide-react";
import Link from "next/link";

// /projeler'deki elle yazılmış Önceki/Sonraki mantığının genelleştirilmiş
// hali -- href her zaman çağıran tarafından üretilir (mevcut filtre/arama
// parametrelerini korumak sayfa başına farklıdır), Pagination yalnızca
// sunar.
export function Pagination({
  page,
  totalPages,
  total,
  itemLabel,
  hrefForPage,
}: {
  page: number;
  totalPages: number;
  total: number;
  itemLabel: string;
  hrefForPage: (page: number) => string;
}) {
  return (
    <div className="flex items-center justify-between text-xs text-text-muted">
      <span>
        {total} {itemLabel}
        {totalPages > 1 && ` · sayfa ${page}/${totalPages}`}
      </span>
      {totalPages > 1 && (
        <div className="flex items-center gap-3">
          {page > 1 && (
            <Link href={hrefForPage(page - 1)} className="flex items-center gap-1 hover:text-gold">
              <ChevronLeft size={14} strokeWidth={1.75} />
              Önceki
            </Link>
          )}
          {page < totalPages && (
            <Link href={hrefForPage(page + 1)} className="flex items-center gap-1 hover:text-gold">
              Sonraki
              <ChevronRight size={14} strokeWidth={1.75} />
            </Link>
          )}
        </div>
      )}
    </div>
  );
}
