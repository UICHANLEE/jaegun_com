import type { ViewerContext } from '../types/domain';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
const state = vi.hoisted(() => ({ viewer: undefined as ViewerContext | undefined }));
vi.mock('../data/AppDataProvider', () => ({ useAppData: () => state }));
import { MorePage } from '../pages/MorePage';
import { mobileNavigationActive } from '../components/AppShell';
beforeEach(() => { state.viewer = {
  profile: { id: 'test-member', displayName: '성도', email: 'member@example.test', globalRole: 'user' },
  membership: { id: 'test-membership', organizationId: 'church-1', userId: 'test-member', role: 'member', status: 'active', executiveOfficeCodes: [] },
}; });
describe('five destination navigation and More', () => {
  it('preserves community tools and account deletion without management for ordinary members', () => {
    render(<MemoryRouter><MorePage /></MemoryRouter>);
    expect(screen.getByRole('link', { name: 'AI 도우미' })).toHaveAttribute('href','/app/ai');
    expect(screen.getByRole('link', { name: '계정 삭제' })).toHaveAttribute('href','/app/account');
    expect(screen.getByRole('link', { name: '임원실·조직도' })).toHaveAttribute('href','/app/organizations');
    expect(screen.getByRole('link', { name: '회의록 작성·조회' })).toHaveAttribute('href','/app/records/minutes');
    expect(screen.getByRole('link', { name: '회계 장부·영수증·결산' })).toHaveAttribute('href','/app/records/finance');
    expect(screen.queryByRole('link', { name: '관리 화면 열기' })).not.toBeInTheDocument();
  });
  it('keeps the minister entry distinct from platform administration', () => {
    state.viewer = { ...state.viewer!, membership: { ...state.viewer!.membership!, role: 'minister' } };
    render(<MemoryRouter><MorePage /></MemoryRouter>);
    expect(screen.getByRole('heading', { name: '목사님·사역자 관리' })).toBeVisible();
    expect(screen.queryByRole('heading', { name: '최고 관리자 관제' })).not.toBeInTheDocument();
  });
  it('maps existing detail URLs to their parent mobile destination', () => {
    for (const path of ['/app/ai','/app/churches/one','/app/profile','/app/records/minutes']) expect(mobileNavigationActive('/app/more',path)).toBe(true);
    expect(mobileNavigationActive('/app/more','/app/posts')).toBe(false);
    expect(mobileNavigationActive('/app/events','/app/events/one')).toBe(true);
    expect(mobileNavigationActive('/app/events','/app/events-evil')).toBe(false);
  });
});
