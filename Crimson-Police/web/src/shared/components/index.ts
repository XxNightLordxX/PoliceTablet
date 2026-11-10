// Src/shared/components · the one component set of all four tablets (officer, supervisor, admin, criminal):

// Src/shared/components · the one component set of all four tablets (officer, supervisor, admin, criminal):
// every screen builds from these. Import from here:
// import { Button, Card, Table, Money, TierBadge } from '../../shared/components';
// Props are documented on each component and in docs/dev/ARCHITECTURE.md §12.

export { Icon, ICON_NAMES } from './Icon';
export type { IconName, IconProps } from './Icon';

export { Button, IconButton, ConfirmButton, CONFIRM_ARM_MS } from './Button';
export type { ButtonProps, ButtonVariant, ButtonSize, IconButtonProps, ConfirmButtonProps } from './Button';

export { Card, Section, Screen } from './Card';
export type { CardProps, SectionProps, ScreenProps } from './Card';

export { Badge, TierBadge, XpBadge, TIER_ORDER } from './Badge';
export type { BadgeProps, BadgeTone } from './Badge';

export { Tabs, SegmentedControl } from './Tabs';
export type { TabItem } from './Tabs';

export { Table, sortRows, filterRows, pageRows } from './Table';
export type { TableColumn, TableProps, TableSort } from './Table';

export { Pager } from './Pager';
export type { PagerProps } from './Pager';

export { ScreenStatus } from './ScreenStatus';

export { Dialog, ConfirmDialog, LayerRootContext } from './Dialog';
export type { DialogProps, ConfirmDialogProps } from './Dialog';

export { Field, TextInput, SearchInput, NumberInput, Select, Textarea, Toggle, Checkbox } from './Form';
export type {
    FieldProps,
    TextInputProps,
    NumberInputProps,
    SelectProps,
    SelectOption,
    TextareaProps,
    ToggleProps,
    CheckboxProps,
} from './Form';

export { ProgressBar, Stat, EmptyState, ErrorState, Spinner, LoadingBlock } from './Feedback';
export type { ProgressBarProps, StatProps, EmptyStateProps, Tone } from './Feedback';

export { Countdown, Money, MoneyRange, Points } from './Numbers';
export type { CountdownProps } from './Numbers';

export { Grid, Stack, Row, Spacer, Divider, KeyValue } from './Layout';
export type { GridProps, StackProps } from './Layout';

export { Toasts } from './Toasts';
export type { ToastsProps } from './Toasts';

export { Watermark, DeptLogo } from './Logo';
export type { WatermarkProps } from './Logo';

export { Avatar } from './Avatar';
export type { AvatarProps } from './Avatar';

export { ErrorBoundary } from './ErrorBoundary';
export { QuietBoundary } from './QuietBoundary';
export { MaintenanceBanner } from './MaintenanceBanner';

export { MoreFold, readMoreOpen, writeMoreOpen, MORE_PREFIX } from './MoreFold';
export type { MoreFoldProps } from './MoreFold';
