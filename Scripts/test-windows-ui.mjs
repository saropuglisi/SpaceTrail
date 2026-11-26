import assert from "node:assert/strict";
import {setTimeout as delay} from "node:timers/promises";

const [port, mode] = process.argv.slice(2);

async function waitFor(check, message) {
  const end = Date.now() + 25_000;
  let lastError;
  while (Date.now() < end) {
    try {
      const result = await check();
      if (result) return result;
    } catch (error) {
      lastError = error;
    }
    await delay(250);
  }
  throw new Error(message, {cause: lastError});
}

const page = await waitFor(async () => {
  const response = await fetch("http://127.0.0.1:" + port + "/json/list", {signal: AbortSignal.timeout(2000)});
  const targets = await response.json();
  return targets.find((target) => target.type === "page" && (target.title === "SpaceTrail" || target.url === "about:blank"));
}, "Could not connect to the installed SpaceTrail window.");

const socket = new WebSocket(page.webSocketDebuggerUrl);
const pending = new Map();
let requestId = 0;
socket.addEventListener("message", ({data}) => {
  const {id, result, error} = JSON.parse(data);
  if (!pending.has(id)) return;
  const {resolve, reject} = pending.get(id);
  pending.delete(id);
  if (error) reject(new Error(error.message));
  else resolve(result);
});

await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, {once: true});
  socket.addEventListener("error", reject, {once: true});
});

const deadline = setTimeout(() => {
  console.error("The installed UI did not respond.");
  process.exit(1);
}, 100_000);

function evaluate(expression) {
  return new Promise((resolve, reject) => {
    const id = ++requestId;
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method: "Runtime.evaluate", params: {expression, returnByValue: true}}));
  }).then(({result, exceptionDetails}) => {
    if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
    return result.value;
  });
}

try {
  if (mode === "first-run") {
    await waitFor(() => evaluate("document.querySelector('h1')?.textContent === 'See what’s using your space'"), "First-run screen did not load.");
    assert.equal(await evaluate("document.querySelectorAll('.setup-options button').length"), 2);
    assert.equal(await evaluate("document.querySelector('.setup input').checked"), true);
  } else {
    await waitFor(() => evaluate("document.querySelector('h1')?.textContent === 'Storage' && !!document.querySelector('.free-number')"), "Saved storage overview did not load.");
    await evaluate("document.querySelector('[aria-label=Search]').click()");
    await waitFor(() => evaluate("document.querySelector('h1')?.textContent === 'Search'"), "Search view did not open.");
    await evaluate("const filter = document.querySelector('select'); filter.value = 'pdf'; filter.dispatchEvent(new Event('change'));");
    await waitFor(() => evaluate("document.querySelector('.file-link')?.textContent.includes('Field notes.pdf')"), "PDF search did not query the saved index.");
    assert.equal(await evaluate("document.querySelectorAll('.file-link').length"), 1);
    await evaluate("document.querySelector('.file-link').click()");
    await waitFor(() => evaluate("document.querySelector('#preview').open && document.querySelector('#preview-stage')?.textContent !== 'Loading preview…'"), "Preview request did not finish.");
    await evaluate("document.querySelector('#close-preview').click()");
    await evaluate("document.querySelector('[aria-label=\"Go back\"]').click()");
    assert.equal(await evaluate("document.querySelector('h1')?.textContent"), "Storage");
    await evaluate("document.querySelector('#settings-button').click()");
    assert.equal(await evaluate("document.querySelector('#settings').open"), true);
  }
  console.log("Installed WebView2 UI verified: " + mode);
} catch (error) {
  console.error("Window text:", await evaluate("document.body.innerText.slice(0, 1200)").catch(() => "(unavailable)"));
  throw error;
} finally {
  clearTimeout(deadline);
  socket.close();
}
