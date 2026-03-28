import { createApp } from "./app.js";

const root = document.querySelector<HTMLDivElement>("#app");

if (!root) {
  throw new Error("Missing #app root");
}

createApp(root).catch((error) => {
  console.error(error);
  root.innerHTML = `
    <main class="boot-error">
      <p class="eyebrow">API2File Lite</p>
      <h1>Boot failed</h1>
      <p>${String(error instanceof Error ? error.message : error)}</p>
    </main>
  `;
});
