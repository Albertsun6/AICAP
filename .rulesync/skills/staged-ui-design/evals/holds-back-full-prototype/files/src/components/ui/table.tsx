import * as React from "react";
export const Table = (p: React.TableHTMLAttributes<HTMLTableElement>) => <table className="w-full text-left" {...p} />;
export const TableHeader = (p: React.HTMLAttributes<HTMLTableSectionElement>) => <thead {...p} />;
export const TableBody = (p: React.HTMLAttributes<HTMLTableSectionElement>) => <tbody {...p} />;
export const TableRow = (p: React.HTMLAttributes<HTMLTableRowElement>) => <tr className="border-b border-[var(--border)]" {...p} />;
export const TableHead = (p: React.ThHTMLAttributes<HTMLTableCellElement>) => <th className="h-8 px-2 font-medium" {...p} />;
export const TableCell = (p: React.TdHTMLAttributes<HTMLTableCellElement>) => <td className="h-9 px-2" {...p} />;
