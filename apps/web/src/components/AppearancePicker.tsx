import { setAppearance, useAppearance, type Appearance } from '../appearance';

export function AppearancePicker({compact = false}: {compact?: boolean}) {
 const value = useAppearance();
 return <label className={`appearance-picker${compact ? ' appearance-picker--compact' : ''}`}>
  <span>화면 모드</span>
  <select aria-label="화면 모드" value={value} onChange={event => setAppearance(event.target.value as Appearance)}>
   <option value="system">시스템 설정</option><option value="light">라이트</option><option value="dark">다크</option>
  </select>
 </label>;
}
