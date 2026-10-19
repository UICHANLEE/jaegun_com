import { ScopedRecordsPage } from './ScopedRecordsPages';
import { useSearchParams } from 'react-router-dom';

/** Route entry points share the exact-scope records screen; authority comes from RPCs. */
export function MeetingMinutesPage() {
 const [params]=useSearchParams();
 return <ScopedRecordsPage kind="minutes" scopeId={params.get('scope')??undefined} eventId={params.get('event')??undefined}/>;
}
export function AccountingLedgerPage() {
 const [params]=useSearchParams();
 return <ScopedRecordsPage kind="finance" scopeId={params.get('scope')??undefined} eventId={params.get('event')??undefined}/>;
}
