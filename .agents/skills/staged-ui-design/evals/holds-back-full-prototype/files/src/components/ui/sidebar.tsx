import * as React from "react";
export const Sidebar = (p: React.HTMLAttributes<HTMLElement>) => <nav className="w-60 shrink-0 border-r border-[var(--border)] p-2" {...p} />;
export const SidebarItem = (p: React.AnchorHTMLAttributes<HTMLAnchorElement>) => <a className="flex h-8 items-center rounded px-2" {...p} />;
