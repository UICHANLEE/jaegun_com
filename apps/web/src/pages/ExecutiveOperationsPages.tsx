import { ScopedRecordsPage } from './ScopedRecordsPages';

/** Route entry points share the exact-scope records screen; authority comes from RPCs. */
export function MeetingMinutesPage() {
 return <ScopedRecordsPage kind="minutes"/>;
}
export function AccountingLedgerPage() {
 return <ScopedRecordsPage kind="finance"/>;
}
