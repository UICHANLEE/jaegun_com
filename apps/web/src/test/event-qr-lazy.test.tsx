import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { EventFieldPanel } from '../pages/EventFieldPanel';
const moduleState = vi.hoisted(() => ({loads: 0}));
vi.mock('jsqr', () => { moduleState.loads++; throw new Error('스캔 모듈 다운로드 실패'); });
vi.mock('../data/AppDataProvider', () => ({useAppData: () => ({reauthenticateWithSocial: vi.fn()})}));
vi.mock('../data/eventField', () => ({
 loadEventField: async () => ({capabilities:['checkin'],can_grant:false,survey:null,plan:{revision:0,vehicles:[]},groups:[],rooms:[],participants:[],staff:[]}),
 fieldDraft: () => ({revision:0,groups:[],rooms:[],vehicles:[],assignments:[]}),
 fieldCapacityError: () => null,
 autoField: vi.fn(), downloadEventWorkbook: vi.fn(), eventFieldRPC: vi.fn(), saveFieldPlan: vi.fn(),
}));
describe('on-demand QR module failure', () => {
 it('does not load the scanner until requested and renders download failure instead of an unhandled rejection', async () => {
  render(<EventFieldPanel occurrenceId="occurrence" startsAt="2026-10-16T00:00:00Z" endsAt="2026-10-16T01:00:00Z" onDirtyChange={()=>{}}/>);
  const open = await screen.findByRole('button', {name:'QR 카메라 체크인'});
  expect(screen.queryByText('스캔 모듈 다운로드 실패')).not.toBeInTheDocument();
  expect(moduleState.loads).toBe(0);
  fireEvent.click(open);
  // Vitest wraps a rejected module factory; assert the surfaced failure state,
  // not an implementation-specific wrapper message.
  expect(await screen.findByRole('alert')).toBeVisible();
  expect(moduleState.loads).toBe(1);
  expect(screen.getByRole('button', {name:'카메라 닫기'})).toBeEnabled();
 });
});
