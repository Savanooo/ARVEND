import { InputHTMLAttributes, forwardRef } from "react";

import { Input } from "./Input";

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, "type"> & {
  label?: string;
  error?: string;
};

export const DateInput = forwardRef<HTMLInputElement, Props>((props, ref) => (
  <Input ref={ref} type="date" {...props} />
));
DateInput.displayName = "DateInput";
