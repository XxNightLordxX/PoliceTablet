// Src/shared/components · the shared UI toolkit. Import from here:
// import { Button, Card, Table, Money, TierBadge } from '../../shared/components';
// Props are documented on each component and in web/README.md.

export { Icon, ICON_NAMES } from './Icon';
export type { IconName, IconProps } from './Icon';

export { Button, IconButton } from './Button';
export type { ButtonProps, ButtonVariant, ButtonSize, IconButtonProps } from './Button';

export { Card, Section, Screen } from './Card';
export type { CardProps, SectionProps, ScreenProps } from './Card';

export { Badge, TierBadge, XpBadge, TIER_ORDER } from './Badge';
export type { BadgeProps, BadgeTone } from './Badge';

export { Tabs, SegmentedControl } from './Tabs';
export type { TabItem } from './Tabs';

export { Table } from './Table';
export type { TableColumn, TableProps } from './Table';

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

export { ErrorBoundary } from './ErrorBoundary';
export { ScreenStub } from './ScreenStub';
