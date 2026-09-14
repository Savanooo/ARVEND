import { ButtonHTMLAttributes, forwardRef } from "react";

type Variant = "primary" | "secondary" | "danger" | "ghost";

interface Props extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  label: string;
}

const base =
  "inline-flex items-center justify-center rounded-md p-2 transition-colors disabled:opacity-50 disabled:cursor-not-allowed";

const variants: Record<Variant, string> = {
  primary: "bg-gold text-text hover:bg-gold-hover",
  secondary: "border border-border bg-transparent text-text hover:bg-surface-hover",
  danger: "border border-danger/40 text-danger hover:bg-danger-soft",
  ghost: "text-text-muted hover:text-text hover:bg-surface-hover",
};

// Yalnızca ikon taşıyan butonlar için -- `label`, aria-label ve title
// olarak kullanılır (ikon-only butonlar erişilebilir bir isim olmadan
// ekran okuyucular için anlamsızdır).
export const IconButton = forwardRef<HTMLButtonElement, Props>(
  ({ variant = "ghost", label, className = "", ...props }, ref) => (
    <button
      ref={ref}
      aria-label={label}
      title={label}
      className={`${base} ${variants[variant]} ${className}`}
      {...props}
    />
  )
);
IconButton.displayName = "IconButton";
