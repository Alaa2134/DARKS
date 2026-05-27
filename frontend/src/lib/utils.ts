import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export const SEVERITY_META: Record<
  Severity,
  { label: string; className: string; dot: string }
> = {
  critical: {
    label: "Critical",
    className: "border-severity-critical/40 bg-severity-critical/15 text-severity-critical",
    dot: "bg-severity-critical",
  },
  high: {
    label: "High",
    className: "border-severity-high/40 bg-severity-high/15 text-severity-high",
    dot: "bg-severity-high",
  },
  medium: {
    label: "Medium",
    className: "border-severity-medium/40 bg-severity-medium/15 text-severity-medium",
    dot: "bg-severity-medium",
  },
  low: {
    label: "Low",
    className: "border-severity-low/40 bg-severity-low/15 text-severity-low",
    dot: "bg-severity-low",
  },
  info: {
    label: "Info",
    className: "border-severity-info/40 bg-severity-info/15 text-severity-info",
    dot: "bg-severity-info",
  },
};
