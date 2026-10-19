import { beforeEach, describe, expect, it, vi } from 'vitest';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { AppearancePicker } from '../components/AppearancePicker';
import { parseAppearance, setAppearance } from '../appearance';

beforeEach(() => { setAppearance('system'); });
describe('device appearance preference', () => {
 it('defaults to system and rejects unknown stored choices', () => {
  expect(parseAppearance('unknown')).toBe('system');
  expect(parseAppearance(null)).toBe('system');
  render(<AppearancePicker/>);
  expect(screen.getByRole('combobox', {name:'화면 모드'})).toHaveValue('system');
  expect(document.documentElement).not.toHaveAttribute('data-theme');
 });
 it('switches immediately, synchronizes controls, and returns to live system CSS', () => {
  render(<><AppearancePicker/><AppearancePicker compact/></>);
  const controls=screen.getAllByRole('combobox', {name:'화면 모드'});
  fireEvent.change(controls[0],{target:{value:'dark'}});
  expect(document.documentElement).toHaveAttribute('data-theme','dark');
  expect(controls[1]).toHaveValue('dark');
  expect(localStorage.getItem('jaegun-appearance-v1')).toBe('dark');
  fireEvent.change(controls[1],{target:{value:'light'}});
  expect(document.documentElement).toHaveAttribute('data-theme','light');
  fireEvent.change(controls[0],{target:{value:'system'}});
  expect(document.documentElement).not.toHaveAttribute('data-theme');
  expect(localStorage.getItem('jaegun-appearance-v1')).toBeNull();
 });
 it('works without persistent storage access', () => {
  const storage=vi.spyOn(window.localStorage,'setItem').mockImplementation(()=>{throw new Error('blocked');});
  try {
   render(<AppearancePicker/>);
   fireEvent.change(screen.getByRole('combobox'),{target:{value:'dark'}});
   expect(document.documentElement).toHaveAttribute('data-theme','dark');
  } finally { storage.mockRestore(); }
 });
 it('handles another tab changing or clearing the preference without reading other data', () => {
  render(<AppearancePicker/>);
  localStorage.setItem('jaegun-appearance-v1','dark');
  act(()=>window.dispatchEvent(new StorageEvent('storage',{key:'jaegun-appearance-v1'})));
  expect(screen.getByRole('combobox')).toHaveValue('dark');
  localStorage.removeItem('jaegun-appearance-v1');
  act(()=>window.dispatchEvent(new StorageEvent('storage',{key:null})));
  expect(document.documentElement).not.toHaveAttribute('data-theme');
 });
 it('loads a saved non-sensitive choice before rendering after reload', async () => {
  localStorage.setItem('jaegun-appearance-v1','light');
  vi.resetModules();
  await import('../appearance');
  expect(document.documentElement).toHaveAttribute('data-theme','light');
 });
});
