import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { OperationsConsolePage } from '../pages/OperationsConsolePage';
import { OperationsAppealPage } from '../pages/OperationsAppealPage';
import { MyReportsPage } from '../pages/MyReportsPage';
const mock = vi.hoisted(() => ({ rpc: vi.fn(), viewer: { profile: { id: 'actor-a' } }, mode: 'supabase', consentGateOpen: true }));
vi.mock('../data/supabase', () => ({ supabase: { rpc: mock.rpc } }));
vi.mock('../data/AppDataProvider', () => ({ useAppData: () => mock }));
const id = '11111111-1111-4111-8111-111111111111';
function appeal(path = id) { return render(<MemoryRouter initialEntries={['/app/reports/'+path+'/appeal']}><Routes><Route path='/app/reports/:reportId/appeal' element={<OperationsAppealPage />} /></Routes></MemoryRouter>); }
describe('operations and appeals', () => {
 beforeEach(() => { vi.clearAllMocks(); mock.viewer.profile.id = 'actor-a'; mock.consentGateOpen = true; mock.mode = 'supabase'; });
 it('loads metrics without any AI or supplier dependency', async () => {
  mock.rpc.mockResolvedValue({ data: { database_bytes: 123 }, error: null }); render(<MemoryRouter><OperationsConsolePage /></MemoryRouter>);
  fireEvent.click(screen.getByRole('button', { name: '조회 / 새로고침' }));
  await waitFor(() => expect(mock.rpc).toHaveBeenCalledTimes(1));
  expect(mock.rpc).toHaveBeenCalledWith('admin_operations_snapshot', {});
  expect(screen.queryByRole('button', { name: '공급자' })).not.toBeInTheDocument();
 });
 it('does not duplicate simultaneous console requests', async () => {
  mock.rpc.mockReturnValue(new Promise(() => {})); render(<MemoryRouter><OperationsConsolePage /></MemoryRouter>);
  const button = screen.getByRole('button', { name: '조회 / 새로고침' }); fireEvent.click(button); fireEvent.click(button);
  expect(mock.rpc).toHaveBeenCalledTimes(1);
 });
 it('does not retain a previous case action when another case fails to load', async () => {
  mock.rpc.mockImplementation(async (name: string, args: Record<string, unknown>) => {
   if (name === 'admin_operations_cases') return { data: { cases: [{id:'case-a',reason_code:'harassment',status:'open'}, {id:'case-b',reason_code:'spam',status:'open'}] }, error:null };
   return args.p_report_id === 'case-a' ? {data:{id:'case-a'},error:null} : {data:null,error:new Error('조회 실패')};
  });
  render(<MemoryRouter><OperationsConsolePage /></MemoryRouter>); fireEvent.click(screen.getByRole('button', { name:'신고·항소' }));
  fireEvent.change(screen.getByRole('textbox', {name:/조사·조치 사유/}), { target: {value:'구체적인 신고 사건을 확인합니다'} });
  fireEvent.click(screen.getByRole('button', { name:'조회 / 새로고침' }));
  fireEvent.click(await screen.findByRole('button', {name:/case-a/}));
  expect(await screen.findByRole('button', {name:'경고'})).toBeVisible();
  fireEvent.click(screen.getByRole('button', {name:/case-b/}));
  await screen.findByRole('alert'); expect(screen.queryByRole('button', {name:'경고'})).not.toBeInTheDocument();
 });
 it('rejects malformed report URLs without calling the backend', () => {
  appeal('bad-id'); expect(screen.getByRole('alert')).toHaveTextContent('올바른 사건 주소');
  expect(screen.getByRole('button', {name:'이의신청 제출'})).toBeDisabled(); expect(mock.rpc).not.toHaveBeenCalled();
 });
 it('validates a reason, submits once, and prevents repeat submission', async () => {
  mock.rpc.mockResolvedValue({data:id,error:null}); appeal();
  const submit = screen.getByRole('button', {name:'이의신청 제출'}); expect(submit).toBeDisabled();
  fireEvent.change(screen.getByRole('textbox'), { target:{value:'이 제재를 다시 검토해 주시기 바랍니다'} });
  fireEvent.click(submit); fireEvent.click(submit);
  await screen.findByText(/이의신청을 제출했습니다/); expect(mock.rpc).toHaveBeenCalledTimes(1); expect(submit).toBeDisabled();
 });
 it('distinguishes an empty list from failure and supports an explicit retry', async () => {
  mock.rpc.mockResolvedValueOnce({data:null,error:new Error('offline')}).mockResolvedValueOnce({data:[],error:null});
  render(<MemoryRouter><MyReportsPage /></MemoryRouter>);
  expect(await screen.findByRole('alert')).toHaveTextContent('불러오지 못했습니다');
  fireEvent.click(screen.getByRole('button', {name:'다시 조회'}));
  await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('표시할 신고·제재가 없습니다'));
 });
 it('allows minimal self-service requests while community consent is stale', async () => {
  mock.consentGateOpen = false; mock.rpc.mockResolvedValue({data:[],error:null});
  render(<MemoryRouter><MyReportsPage /></MemoryRouter>);
  await waitFor(() => expect(mock.rpc).toHaveBeenCalledWith('operations_my_reports', {p_offset:0}));
 });
});
