interface BrandProps {
  compact?: boolean;
  inverse?: boolean;
}

export function Brand({ compact = false, inverse = false }: BrandProps) {
  return (
    <div className={`brand ${compact ? "brand--compact" : ""} ${inverse ? "brand--inverse" : ""}`}>
      <img className="brand__mark" src="/assets/brand-mark-tight.png" alt="" />
      <span className="brand__name">재건 공동체</span>
    </div>
  );
}
