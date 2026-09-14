import { Loader2 } from "lucide-react";
import { ButtonHTMLAttributes, forwardRef } from "react";

type Variant = "primary" | "secondary" | "danger" | "ghost";

interface Props extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  loading?: boolean;
}

const base =
  "inline-flex items-center justify-center gap-2 rounded-md px-4 py-2 text-sm font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed";

const variants: Record<Variant, string> = {
  primary: "bg-gold text-text hover:bg-gold-hover",
  secondary:
    "border border-border bg-transparent text-text hover:bg-surface-hover",
  danger: "border border-danger/40 text-danger hover:bg-danger-soft",
  ghost: "text-text-muted hover:text-text hover:bg-surface-hover",
};

export const Button = forwardRef<HTMLButtonElement, Props>(
  ({ variant = "primary", loading = false, disabled, className = "", children, ...props }, ref) => (
    <button
      ref={ref}
      disabled={disabled || loading}
      className={`${base} ${variants[variant]} ${className}`}
      {...props}
    >
      {loading && <Loader2 size={14} strokeWidth={2} className="animate-spin" />}
      {children}
    </button>
  )
);
Button.displayName = "Button";
