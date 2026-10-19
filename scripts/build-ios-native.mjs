import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const args = new Set(process.argv.slice(2));
if ([...args].some((arg) => arg !== '--release' && !arg.startsWith('--rpc-snapshot='))) throw new Error('지원하지 않는 빌드 옵션입니다.');
const release = args.has('--release');
if (release) {
  const snapshots = [...args].filter(arg => arg.startsWith('--rpc-snapshot='));
  if (snapshots.length !== 1 || !snapshots[0].slice('--rpc-snapshot='.length)) throw new Error('출시 전 fresh RPC metadata 검사가 필요합니다: --rpc-snapshot=/absolute/path.json');
  const check = spawnSync(process.execPath, [fileURLToPath(new URL('./releases/check-native-rpcs.mjs', import.meta.url)), '--snapshot', snapshots[0].slice('--rpc-snapshot='.length)], { stdio: 'inherit' });
  if (check.error) throw check.error;
  if (check.status !== 0) process.exit(check.status ?? 1);
}
const cwd = fileURLToPath(new URL('../apps/ios-native/', import.meta.url));
for (const [command, commandArgs] of [
  ['xcodegen', ['generate']],
  ['xcodebuild', ['-workspace', 'JaegunNative.xcworkspace', '-scheme', 'JaegunNative',
    '-configuration', release ? 'Release' : 'Debug',
    '-destination', release ? 'generic/platform=iOS' : 'generic/platform=iOS Simulator',
    '-derivedDataPath', '.native-build',
    ...(release ? ['CODE_SIGNING_ALLOWED=NO'] : ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_REQUIRED=YES']),
    'build']],
]) {
  const result = spawnSync(command, commandArgs, { cwd, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
if (release) console.log('순수 SwiftUI Release 컴파일 완료. 서명·실기기·TestFlight·App Store 출시는 별도 검증입니다.');
