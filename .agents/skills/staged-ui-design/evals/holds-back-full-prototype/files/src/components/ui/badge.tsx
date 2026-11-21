import * as React from "react";
export function Badge({ tone = "neutral", ...p }: React.HTMLAttributes<HTMLSpanElement> & { tone?: "neutral" | "ok" | "warn" | "critical" }) {
  return <span data-tone={tone} className="inline-flex h-5 items-center rounded px-1.5 text-[11px]" {...p} />;
}
