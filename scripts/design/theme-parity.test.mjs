import { readFileSync } from "node:fs";
import test from "node:test";
import assert from "node:assert/strict";

const css = readFileSync(new URL("../../apps/web/src/theme.css", import.meta.url), "utf8");
const native = readFileSync(new URL("../../apps/ios-native/Sources/NativeDesign.swift", import.meta.url), "utf8");
const variables = (block) => Object.fromEntries([...block.matchAll(/--([\w-]+):\s*(#[a-f0-9]{6})\s*;/gi)].map((item) => [item[1], item[2].toLowerCase()]));
const light = variables(css.slice(0, css.indexOf("@media")));
const start = css.indexOf("@media (prefers-color-scheme: dark)");
const dark = { ...light, ...variables(css.slice(start, css.indexOf("\n}\n", start))) };
function luminance(color) {
  assert.match(color ?? "", /^#[a-f0-9]{6}$/i);
  const rgb = [1, 3, 5].map((start) => parseInt(color.slice(start, start + 2), 16) / 255)
    .map((value) => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
  return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
}
function contrast(a, b) {
  const [low, high] = [luminance(a), luminance(b)].sort((x, y) => x - y);
  return (high + .05) / (low + .05);
}
for (const [mode, tokens] of [["light", light], ["dark", dark]]) {
  test(`${mode} text and focus contrast meet shared palette thresholds`, () => {
    for (const text of ["community-ink", "community-muted"]) {
      for (const background of ["community-bg", "community-surface", "community-elevated"]) {
        assert.ok(contrast(tokens[text], tokens[background]) >= 4.5, `${text}/${background}`);
      }
    }
    for (const tone of ["green", "orange", "blue"]) {
      assert.ok(contrast(tokens[`community-${tone}-ink`], tokens[`community-${tone}-soft`]) >= 4.5, tone);
    }
    assert.ok(contrast(tokens["community-on-solid"], tokens["community-solid-green"]) >= 4.5);
    assert.ok(contrast(tokens["community-focus"], tokens["community-surface"]) >= 3);
  });
}
test("logo accents and automatic dark appearance are preserved", () => {
  assert.equal(light["community-orange"], "#fc8401");
  assert.equal(light["community-green"], "#67b42a");
  assert.equal(light["community-blue"], "#0498e1");
  assert.ok(css.includes("prefers-color-scheme: dark"));
});
test("explicit dark matches automatic dark; explicit light excludes the dark media rule", () => {
  const explicit = variables(css.match(/:root\[data-theme="dark"\]\s*\{([^}]+)\}/s)?.[1] ?? '');
  for (const [key, value] of Object.entries(explicit)) assert.equal(value, dark[key], key);
  assert.ok(Object.keys(explicit).length > 20);
  assert.ok(css.includes(':root:not([data-theme="light"])'));
  const app = readFileSync(new URL('../../apps/ios-native/Sources/JaegunNativeApp.swift',import.meta.url),'utf8');
  assert.ok(app.includes('.preferredColorScheme(NativeAppearance(rawValue: appearance)?.colorScheme)'));
  assert.ok(native.includes('case .system: return nil'));
});
test("web and native semantic palette remains identical in both appearances", () => {
  for (const [swift, key] of [["canvas", "bg"], ["surface", "surface"], ["ink", "ink"], ["muted", "muted"], ["line", "line"], ["forest", "green-ink"], ["solidGreen", "solid-green"], ["orange", "orange-ink"], ["blue", "blue-ink"]]) {
    const match = native.match(new RegExp(`static let ${swift} = token\\(0x([a-f0-9]{6}), 0x([a-f0-9]{6})\\)`));
    assert.equal(match?.[1], light[`community-${key}`].slice(1), `${swift} light`);
    assert.equal(match?.[2], dark[`community-${key}`].slice(1), `${swift} dark`);
  }
  assert.ok(native.includes("traits.userInterfaceStyle == .dark"));
});
