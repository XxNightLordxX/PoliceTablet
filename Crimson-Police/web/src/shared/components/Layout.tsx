import type { CSSProperties, HTMLAttributes, ReactNode } from 'react';
import { cx } from '../cx';

type Space = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 8;
const gapPx = (g: Space) => `${g * 4}px`;

export interface GridProps extends HTMLAttributes<HTMLDivElement> {
  /** Fixed column count (e.g. 3), or a CSS grid-template-columns string. */
  cols?: number | string;
  /** Responsive auto-fill: minimum column width in px (overrides cols). */
  min?: number;
  /** Gap in 4px steps (default 4 = 16px). */
  gap?: Space;
  align?: CSSProperties['alignItems'];
  children?: ReactNode;
}

/** CSS grid helper: <Grid cols={3}>, <Grid cols="2fr 1fr">, <Grid min={220}>. */
export function Grid({ cols = 2, min, gap = 4, align, className, style, children, ...rest }: GridProps) {
  const template = min ? `repeat(auto-fill, minmax(${min}px, 1fr))` : typeof cols === 'number' ? `repeat(${cols}, minmax(0, 1fr))` : cols;
  return (
    <div className={cx('cp-grid', className)} style={{ gridTemplateColumns: template, gap: gapPx(gap), alignItems: align, ...style }} {...rest}>
      {children}
    </div>
  );
}

export interface StackProps extends HTMLAttributes<HTMLDivElement> {
  /** 'col' (default) or 'row'. */
  direction?: 'row' | 'col';
  gap?: Space;
  align?: CSSProperties['alignItems'];
  justify?: CSSProperties['justifyContent'];
  wrap?: boolean;
  /** flex: 1 */
  grow?: boolean;
  children?: ReactNode;
}

/** Flex stack (column by default). */
export function Stack({ direction = 'col', gap = 3, align, justify, wrap, grow, className, style, children, ...rest }: StackProps) {
  return (
    <div
      className={cx('cp-stack', className)}
      style={{
        flexDirection: direction === 'row' ? 'row' : 'column',
        gap: gapPx(gap),
        alignItems: align ?? (direction === 'row' ? 'center' : undefined),
        justifyContent: justify,
        flexWrap: wrap ? 'wrap' : undefined,
        flex: grow ? 1 : undefined,
        ...style,
      }}
      {...rest}
    >
      {children}
    </div>
  );
}

/** Horizontal Stack (items centred). */
export function Row(props: Omit<StackProps, 'direction'>) {
  return <Stack direction="row" gap={2} {...props} />;
}

/** Pushes the following siblings to the end of a Row. */
export function Spacer() {
  return <div className="cp-spacer" aria-hidden />;
}

export function Divider({ className }: { className?: string }) {
  return <hr className={cx('cp-divider', className)} />;
}

/** Small uppercase label for key/value lists. */
export function KeyValue({ label, children, className }: { label: ReactNode; children?: ReactNode; className?: string }) {
  return (
    <div className={cx('cp-kv', className)}>
      <span className="cp-kv__label">{label}</span>
      <span className="cp-kv__value">{children}</span>
    </div>
  );
}
