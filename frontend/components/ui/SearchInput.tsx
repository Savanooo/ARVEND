import { Search } from "lucide-react";
import { InputHTMLAttributes, forwardRef } from "react";

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, "type">;

export const SearchInput = forwardRef<HTMLInputElement, Props>(({ className = "", ...props }, ref) => (
  <div className="relative">
    <Search
      size={16}
      strokeWidth={1.75}
      className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-text-muted"
    />
    <input
      ref={ref}
      type="search"
      className={`w-full rounded-md border border-border bg-surface py-2 pl-9 pr-3 text-sm text-text placeholder:text-text-muted/60 outline-none focus:border-gold ${className}`}
      {...props}
    />
  </div>
));
SearchInput.displayName = "SearchInput";
