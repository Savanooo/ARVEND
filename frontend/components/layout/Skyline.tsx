/**
 * Logodaki gökdelen silüetinden esinlenen, çok düşük opaklıklı (~%6) bir
 * arka plan deseni. Sidebar'a markaya özgü, şablon hissi vermeyen bir
 * doku katmak için — jenerik düz renk yerine.
 */
export function Skyline({ className = "" }: { className?: string }) {
  return (
    <svg
      className={`pointer-events-none absolute inset-x-0 bottom-0 h-40 w-full opacity-[0.06] ${className}`}
      viewBox="0 0 400 160"
      preserveAspectRatio="none"
      fill="currentColor"
      aria-hidden
    >
      <rect x="10" y="60" width="28" height="100" />
      <rect x="46" y="30" width="20" height="130" />
      <rect x="74" y="80" width="24" height="80" />
      <rect x="110" y="45" width="18" height="115" />
      <rect x="136" y="95" width="30" height="65" />
      <rect x="176" y="20" width="22" height="140" />
      <rect x="206" y="70" width="26" height="90" />
      <rect x="242" y="50" width="18" height="110" />
      <rect x="268" y="90" width="28" height="70" />
      <rect x="304" y="35" width="20" height="125" />
      <rect x="332" y="75" width="24" height="85" />
      <rect x="364" y="55" width="22" height="105" />
    </svg>
  );
}
