import { prepareNativeRuntime } from "./runtime";

function showStartupFailure() {
  const root = document.getElementById("root");
  if (!root) return;
  const main = document.createElement("main");
  main.className = "system-page";
  const section = document.createElement("section");
  section.className = "system-card";
  const title = document.createElement("h1");
  title.textContent = "앱의 안전한 저장소를 준비하지 못했어요";
  const description = document.createElement("p");
  description.textContent = "앱을 완전히 종료한 뒤 다시 열어 주세요. 같은 문제가 계속되면 운영자에게 문의해 주세요.";
  section.append(title, description);
  main.append(section);
  root.replaceChildren(main);
}

async function start() {
  try {
    await prepareNativeRuntime();
    await import("../main");
  } catch {
    await import("../styles.css");
    showStartupFailure();
  }
}

void start();
