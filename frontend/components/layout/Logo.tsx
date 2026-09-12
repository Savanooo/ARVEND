import Image from "next/image";

export function Logo({ size = 36 }: { size?: number }) {
  return (
    <Image
      src="/logo.png"
      alt="Arvend Yapı"
      width={size}
      height={size}
      className="rounded-md"
      priority
    />
  );
}
