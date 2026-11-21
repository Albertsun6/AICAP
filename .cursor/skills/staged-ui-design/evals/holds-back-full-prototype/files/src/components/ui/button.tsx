import * as React from "react";
type Props = React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "default" | "outline" | "ghost" | "destructive" };
export function Button({ variant = "default", className = "", ...props }: Props) {
  return <button data-variant={variant} className={`inline-flex h-8 items-center rounded-[var(--radius)] px-3 ${className}`} {...props} />;
}
