// "use server" dosyaları yalnızca async fonksiyon export edebilir, bu
// yüzden cookie adı burada, düz bir sabit olarak tutulur -- hem
// sidebar-actions.ts hem AppShell.tsx aynı sabiti kullanır.
export const SIDEBAR_COLLAPSED_COOKIE = "sidebar_collapsed";
