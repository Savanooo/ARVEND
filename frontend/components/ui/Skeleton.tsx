// Yükleme durumu göstergesi -- animasyon burada dekoratif değil,
// işlevsel (verinin henüz gelmediğini bildirir), bu yüzden "gereksiz
// animasyon" kuralına aykırı değildir.
export function Skeleton({ className = "" }: { className?: string }) {
  return <div className={`animate-pulse rounded-md bg-surface-hover ${className}`} />;
}
