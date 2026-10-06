import Image from "next/image";

// Platformun (ARVEND) logosu -- bir müşteri firmanın logosu DEĞİLDİR;
// firmaların müşterilerine açık sayfalarda kullanılmaz (bkz.
// PublicPageHeader).
export function Logo({ size = 36 }: { size?: number }) {
  return (
    <Image
      src="/logo.png"
      alt="ARVEND"
      width={size}
      height={size}
      className="rounded-md"
      priority
    />
  );
}
