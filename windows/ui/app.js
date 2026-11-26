"use strict";

const $ = (id) => document.getElementById(id);
const svgNamespace = "http://www.w3.org/2000/svg";
const icons = {
  storage: "M4 5h16l2 9v5H2v-5l2-9Zm-2 9h20M6 17h2m3 0h1",
  files: "M9 3h7l4 4v12H9V3Zm7 0v5h4M6 7H4v14h12",
  folders: "M3 7V5h6l2 2h10v12H3V7Zm0 3h18",
  search: "M10.5 3a7.5 7.5 0 1 0 0 15 7.5 7.5 0 0 0 0-15Zm5.3 12.8L21 21",
  map: "M3 4h18v16H3V4Zm0 8h8m0-8v16m0-6h10",
  settings: "M12 3l2 2 2.8-.1.8 2.7L20 9l-1 3 1 3-2.4 1.4-.8 2.7L14 19l-2 2-2-2-2.8.1-.8-2.7L4 15l1-3-1-3 2.4-1.4.8-2.7L10 5l2-2Zm0 6a3 3 0 1 0 0 6 3 3 0 0 0 0-6Z",
  file: "M6 3h8l4 4v14H6V3Zm8 0v5h4M9 12h6m-6 4h6",
  right: "m9 6 6 6-6 6",
  left: "m15 6-6 6 6 6",
  up: "M12 19V5m-6 6 6-6 6 6",
  close: "m6 6 12 12M6 18 18 6",
  info: "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Zm0-11v6m0-10h.01",
  pin: "M13 5h6v6m0-6-8 8M10 6H5v13h13v-5",
  check: "m5 12 4 4L19 6",
  activity: "M2 12h4l3-6 5 12 3-6h5",
};
const sections = {
  storage: ["Storage", "See what’s taking up space and what grew recently."],
  files: ["Files", "Find the files taking up the most space."],
  folders: ["Folders", "Browse your drive and see how much each folder uses."],
  search: ["Search", "Find files and folders by name or file type."],
  map: ["Map", "Explore your storage by size. Open a block to see what’s inside."],
};
const formats = [
  ["", "Any file type"], ["pdf", "PDF"], ["image", "Images"], ["video", "Videos"],
  ["audio", "Audio"], ["document", "Documents"], ["ebook", "Books"],
  ["archive", "Archives"], ["installer", "Installers"],
];
const phases = {
  loading: "Connecting to SpaceTrail",
  starting: "Starting the first scan",
  scanning: "First scan in progress",
  updating: "Updating the index",
  current: "Index up to date",
  paused: "Background updates paused",
};
const labels = {name: "Name", disk: "On disk", logical: "File size", modified: "Modified"};
const numbers = new Intl.NumberFormat("en");
const date = new Intl.DateTimeFormat("en", {month: "short", day: "numeric", year: "numeric"});
const chartDate = new Intl.DateTimeFormat("en", {month: "short", day: "numeric"});
const mapColors = ["#303c5b", "#3c4b77", "#4b5087", "#5c4b8f", "#6c4993", "#82509a"];

const freshView = (section) => ({
  section, folder: null, query: "", format: "", hide_system: true, sort: "disk", ascending: false,
  offset: 0, days: 7,
});
let view = freshView("storage");
let stack = [view];
let position = 0;
let serial = 0;
let config = null;
let loaded = null;
let status = {phase: "loading", indexed: 0, processed: 0, blocked: 0, capacity: null};
let previewToken = 0;
let previewEntry = null;
let previewTrigger = null;
let setupStartup = true;
let lastHistoryShortcut = -Infinity;

function node(tag, classes, content) {
  const result = document.createElement(tag);
  if (classes) result.className = classes;
  if (content !== undefined) result.textContent = content;
  return result;
}

function svg(tag, attributes) {
  const result = document.createElementNS(svgNamespace, tag);
  for (const [key, value] of Object.entries(attributes)) result.setAttribute(key, value);
  return result;
}

function icon(name) {
  const img = svg("svg", {viewBox: "0 0 24 24", class: "icon", "aria-hidden": "true", fill: "none",
    stroke: "currentColor", "stroke-width": 1.6, "stroke-linecap": "round", "stroke-linejoin": "round"});
  img.append(svg("path", {d: icons[name]}));
  return img;
}

function button(label, glyph, click, kind = "button") {
  const control = node("button", kind);
  control.type = "button";
  if (glyph) control.append(icon(glyph));
  if (kind === "square") {
    control.setAttribute("aria-label", label);
    control.title = label;
  } else {
    control.append(node("span", "", label));
  }
  control.addEventListener("click", click);
  return control;
}

function send(command, fields = {}) {
  window.ipc?.postMessage(JSON.stringify({command, ...fields}));
}

function formatBytes(value, estimated = false) {
  let bytes = Math.max(value, 0);
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  while (bytes >= 1000 && index < units.length - 1) {
    bytes /= 1000;
    index += 1;
  }
  return (estimated ? "≈ " : "") + bytes.toLocaleString("en", {maximumFractionDigits: index ? 1 : 0}) + " " + units[index];
}

function parentPath(path) {
  const slash = path.lastIndexOf("\\");
  return slash === 2 ? path.slice(0, 3) : path.slice(0, slash);
}

function pathLabel(path, classes = "path") {
  const text = node("span", classes, path);
  text.title = path;
  return text;
}

function loadView(keepContent = false) {
  serial += 1;
  if (!keepContent) {
    loaded = null;
    renderResults();
  }
  send("view", {...view, id: serial});
}

function go(next, focusQuery = false) {
  if (!config?.root) return;
  stack = stack.slice(0, position + 1);
  stack.push(next);
  if (stack.length > 75) stack.shift();
  position = stack.length - 1;
  view = next;
  showView(focusQuery);
}

function changeHistory(delta) {
  const next = position + delta;
  if (next < 0 || next >= stack.length) return;
  position = next;
  view = stack[position];
  showView();
}

function historyShortcut(delta) {
  if (document.querySelector("dialog[open]") || performance.now() - lastHistoryShortcut < 130) return;
  lastHistoryShortcut = performance.now();
  changeHistory(delta);
}

function showView(focusQuery = false) {
  loaded = null;
  window.scrollTo(0, 0);
  renderScreen();
  loadView();
  if (focusQuery) $("query")?.focus();
}

function updateView(changes, keepContent = false) {
  view = {...view, ...changes};
  stack[position] = view;
  loadView(keepContent);
}

function openEntry(entry, trigger) {
  if (entry.folder) {
    go({...freshView(view.section === "map" ? "map" : "folders"), folder: entry.id});
  } else {
    openPreview(entry, trigger);
  }
}

function renderNavigation() {
  $("navigation").replaceChildren();
  for (const [key, [label]] of Object.entries(sections)) {
    const control = button(label, key, () => {
      if (view.section !== key) go(freshView(key), key === "search");
    }, "nav-button");
    control.setAttribute("aria-label", label);
    control.title = label;
    if (key === view.section && config?.root) control.setAttribute("aria-current", "page");
    control.disabled = !config?.root;
    $("navigation").append(control);
  }
}

function indexing() {
  return ["loading", "starting", "scanning"].includes(status.phase);
}

function empty(glyph, title, message) {
  const region = node("div", "empty");
  region.append(glyph === "loading" ? node("span", "spinner") : icon(glyph));
  region.append(node("h2", "", title));
  if (message) region.append(node("p", "", message));
  return region;
}

function renderScreen() {
  renderNavigation();
  const screen = $("screen");
  screen.replaceChildren();
  if (!config) {
    screen.append(empty("loading", "Opening SpaceTrail"));
    return;
  }
  if (!config.root) {
    renderSetup(screen);
    return;
  }
  const header = node("header", "page-header");
  const heading = node("div");
  const [title, description] = sections[view.section];
  heading.append(node("h1", "", title), node("p", "", description));
  const actions = node("div", "heading-actions");
  const back = button("Go back", "left", () => changeHistory(-1), "square");
  const forward = button("Go forward", "right", () => changeHistory(1), "square");
  back.disabled = position === 0;
  forward.disabled = position === stack.length - 1;
  actions.append(back, forward);
  header.append(heading, actions);
  screen.append(header);
  if (view.section === "storage") renderOverview(screen);
  else renderBrowser(screen);
}

function renderSetup(screen) {
  const setup = node("section", "setup");
  const graphic = node("div", "hero-icon");
  graphic.append(icon("storage"));
  const choices = node("div", "setup-options");
  for (const [drive, glyph, name, detail] of [
    [true, "storage", "Scan Windows drive", config.drive || "Your main drive"],
    [false, "folders", "Choose a folder", "Scan just one location, including another drive."],
  ]) {
    const control = node("button", drive ? "option default" : "option");
    control.type = "button";
    const copy = node("div");
    copy.append(node("span", "name", name), node("span", "caption", detail));
    control.append(icon(glyph), copy, icon("right"));
    control.addEventListener("click", () => send("scan", {drive, startup: setupStartup}));
    choices.append(control);
  }
  const check = node("label", "check");
  const input = node("input");
  input.type = "checkbox";
  input.checked = setupStartup;
  input.addEventListener("change", () => { setupStartup = input.checked; });
  check.append(input, "Start background updates at sign-in");
  setup.append(graphic, node("h1", "", "See what’s using your space"),
    node("p", "", "Choose a location to scan. SpaceTrail saves the results on this PC and keeps them up to date in the background."),
    choices, check);
  screen.append(setup);
}

function renderOverview(screen) {
  const top = node("div", "overview-top");
  const capacity = node("section", "capacity");
  capacity.id = "capacity";
  const history = node("section", "history");
  const head = node("div", "history-head");
  const ranges = node("div", "range");
  ranges.setAttribute("role", "group");
  ranges.setAttribute("aria-label", "Storage history and growth range");
  for (const days of [7, 30, 90]) {
    const item = button(days + " days", null, () => {
      if (view.days !== days) updateView({days}, true);
      ranges.querySelectorAll("button").forEach((value) => value.setAttribute("aria-pressed", String(value === item)));
    }, "");
    item.setAttribute("aria-pressed", String(days === view.days));
    ranges.append(item);
  }
  const chart = node("div");
  chart.id = "chart";
  head.append(node("h2", "", "Usage history"), ranges);
  history.append(head, chart);
  top.append(capacity, history);
  const monitor = node("div", "monitor");
  monitor.id = "monitor";
  const rankings = node("div", "rankings");
  for (const [key, title, description, action] of [
    ["recent", "Recent growth", "Files that added the most space", null],
    ["folders", "Largest folders", "One folder per branch", "folders"],
    ["largest", "Largest files", "By space used on disk", "files"],
  ]) {
    const section = node("section", "rank-section");
    const row = node("div", "section-head");
    row.append(node("h2", "", title));
    if (action) row.append(button("Browse " + action, null, () => go(freshView(action)), "quiet-link"));
    const results = node("div");
    results.id = key + "-ranking";
    section.append(row, node("p", "rank-help", description), results);
    rankings.append(section);
  }
  screen.append(top, monitor, rankings);
  renderStatus();
}

function meter(capacity) {
  const used = Math.max(0, capacity.total - capacity.free);
  const container = node("div", "meter");
  container.setAttribute("role", "meter");
  container.setAttribute("aria-label", "Disk space used");
  container.setAttribute("aria-valuemin", "0");
  container.setAttribute("aria-valuemax", String(capacity.total));
  container.setAttribute("aria-valuenow", String(used));
  container.setAttribute("aria-valuetext", formatBytes(used) + " used of " + formatBytes(capacity.total));
  const fill = node("div");
  fill.style.width = Math.min(100, (used / capacity.total) * 100) + "%";
  container.append(fill);
  return container;
}

function renderStatus() {
  const capacity = status.capacity;
  const root = config?.root;
  const sidebar = $("sidebar-drive");
  sidebar.hidden = !(capacity && root);
  if (!sidebar.hidden) {
    const label = node("div", "drive-name");
    label.append(icon("storage"), pathLabel(root, "path"));
    sidebar.replaceChildren(label, meter(capacity), node("p", "muted number", formatBytes(capacity.free) + " free"));
  }
  if ($("capacity") && root) {
    const label = node("div", "drive-name");
    label.append(icon("storage"), pathLabel(root, "path"));
    if (capacity) {
      const count = node("p", "free-number number");
      count.append(node("strong", "", formatBytes(capacity.free)), node("span", "", "free"));
      $("capacity").replaceChildren(label, count, meter(capacity),
        node("p", "capacity-info", formatBytes(capacity.total - capacity.free) + " used of " + formatBytes(capacity.total)));
    } else {
      $("capacity").replaceChildren(label, node("p", "muted", "Disk capacity unavailable"));
    }
  }
  const monitor = $("monitor");
  if (monitor) {
    const phase = node("div", "monitor-state");
    phase.dataset.phase = status.phase;
    const indicator = icon(status.phase === "current" ? "check" : "activity");
    indicator.classList.add("indicator");
    phase.append(indicator, node("strong", "", phases[status.phase] || phases.loading));
    const count = status.phase === "scanning" || status.phase === "starting"
      ? numbers.format(status.processed) + " items examined"
      : numbers.format(status.indexed) + " files indexed";
    const detail = node("span", "monitor-count number", count + (status.blocked ? " · Limited folder access" : ""));
    if (status.blocked) detail.title = numbers.format(status.blocked) + " folders could not be read";
    monitor.replaceChildren(phase, detail);
  }
  if ($("browser-state")) {
    $("browser-state").textContent = status.phase === "scanning" || status.phase === "starting"
      ? phases[status.phase] + " · " + numbers.format(status.processed) + " items examined"
      : "";
    $("browser-state").hidden = !$("browser-state").textContent;
  }
  if (status.phase === "paused") showMessage("Background updates are paused. Saved results are still available.", true, "broker");
  else if ($("message").dataset.reason === "broker") clearMessage();
}

function renderChart(history) {
  const container = $("chart");
  if (!history || history.length < 2) {
    container.replaceChildren(node("p", "history-empty", !history
      ? "Loading usage history…" : "Usage history appears as SpaceTrail records disk activity."));
    return;
  }
  const used = history.map((point) => Math.max(0, point.capacity - point.free));
  const min = Math.min(...used);
  const max = Math.max(...used);
  const pad = Math.max((max - min) * .12, 10_000_000);
  const low = Math.max(0, min - pad);
  const high = max + pad;
  const start = history[0].hour;
  const end = history.at(-1).hour;
  const geometry = node("div", "chart");
  const ticks = node("div", "axis-y");
  ticks.setAttribute("aria-hidden", "true");
  ticks.append(node("span", "", formatBytes(high)), node("span", "", formatBytes(low)));
  const graphic = svg("svg", {viewBox: "0 0 600 83", preserveAspectRatio: "none", role: "img",
    "aria-label": "Disk used from " + chartDate.format(start * 1000) + " to " + chartDate.format(end * 1000)
      + ", starting at " + formatBytes(used[0]) + " and ending at " + formatBytes(used.at(-1))});
  for (const y of [1, 41.5, 82]) {
    graphic.append(svg("line", {x1: 0, y1: y, x2: 600, y2: y, stroke: "#3c4863", "vector-effect": "non-scaling-stroke"}));
  }
  const points = history.map((point, index) => {
    const x = (point.hour - start) / (end - start) * 600;
    const y = 78 - (used[index] - low) / (high - low) * 73;
    return x.toFixed(2) + "," + y.toFixed(2);
  }).join(" ");
  graphic.append(svg("polygon", {points: "0,82 " + points + " 600,82", fill: "#343c63", opacity: ".75"}));
  graphic.append(svg("polyline", {points, fill: "none", stroke: "#abb6ff", "stroke-width": 2, "vector-effect": "non-scaling-stroke"}));
  const times = node("div", "axis-x");
  times.setAttribute("aria-hidden", "true");
  for (const time of [start, end]) times.append(node("span", "", chartDate.format(time * 1000)));
  geometry.append(ticks, graphic, times);
  container.replaceChildren(geometry);
}

function entryName(entry, includePath) {
  const name = node("span", "rank-name");
  const title = node("strong", "", entry.name);
  title.title = entry.name;
  name.append(title);
  if (includePath) {
    const path = node("small", "path", parentPath(entry.path));
    path.title = entry.path;
    name.append(path);
  }
  return name;
}

function rank(key, entries) {
  const container = $(key + "-ranking");
  if (!entries?.length) {
    const messages = {
      recent: "No file growth recorded in this period.",
      folders: "No large folders found yet.",
      largest: "No files indexed yet.",
    };
    container.replaceChildren(node("p", "empty inline", indexing() ? "Waiting for the first results…" : messages[key]));
    return;
  }
  const list = node("ul", "ranking");
  for (const entry of entries.slice(0, 5)) {
    const control = node("button", "rank-button");
    control.type = "button";
    control.dataset.entry = entry.id;
    const size = entry.growth > 0 ? "+" + formatBytes(entry.growth, entry.estimated) : formatBytes(entry.allocated, entry.estimated);
    control.append(icon(entry.folder ? "folders" : "file"), entryName(entry, true),
      node("span", "rank-value number" + (entry.growth > 0 ? " growth" : ""), size), icon("right"));
    control.addEventListener("click", () => openEntry(entry, control));
    const item = node("li");
    item.append(control);
    list.append(item);
  }
  replaceResults(container, list);
}

function renderBrowser(screen) {
  if (view.section === "folders" || view.section === "map") {
    const breadcrumb = node("div", "folder-path");
    breadcrumb.id = "folder-path";
    screen.append(breadcrumb);
  }
  if (view.section !== "map") {
    const form = node("form", "filter-bar");
    form.setAttribute("role", "search");
    const field = node("label", "search-field");
    const qualifier = view.section === "folders" ? "Search this folder" : "Search by name";
    const query = node("input");
    query.type = "search";
    query.id = "query";
    query.value = view.query;
    query.placeholder = qualifier;
    query.maxLength = 240;
    field.append(icon("search"), node("span", "sr-only", qualifier), query);
    const format = node("select");
    format.setAttribute("aria-label", "File type");
    for (const [value, text] of formats) {
      const option = node("option", "", text);
      option.value = value;
      format.append(option);
    }
    format.value = view.format;
    format.addEventListener("change", () => submit());
    const search = node("button", "button primary", "Search");
    search.type = "submit";
    const submit = () => updateView({query: query.value.trim(), format: format.value, offset: 0});
    form.addEventListener("submit", (event) => { event.preventDefault(); submit(); });
    form.append(field, format, search);
    screen.append(form);
    if (view.section !== "folders") {
      const options = node("div", "file-options");
      const system = node("label", "check");
      const checkbox = node("input");
      checkbox.type = "checkbox";
      checkbox.checked = !view.hide_system;
      checkbox.addEventListener("change", () => updateView({hide_system: !checkbox.checked, offset: 0}));
      system.append(checkbox, "Show system files");
      options.append(system);
      const queryInfo = node("span", "path");
      queryInfo.id = "query-info";
      options.append(queryInfo);
      screen.append(options);
    }
  }
  const indexState = node("p", "muted rank-help");
  indexState.id = "browser-state";
  indexState.hidden = true;
  const results = node("div");
  results.id = "browser-results";
  results.setAttribute("aria-live", "polite");
  screen.append(indexState, results);
  renderStatus();
}

function renderFolderPath(folder) {
  const container = $("folder-path");
  if (!container) return;
  const folderPath = folder?.path || config.root;
  const up = button("Go up one folder", "up", () => {
    go({...freshView(view.section), folder: folder.parent});
  }, "square");
  up.disabled = folder?.parent == null;
  if (folderPath !== config.root) {
    const root = button("Scan location", "storage", () => go(freshView(view.section)));
    container.replaceChildren(up, root, pathLabel(folderPath));
  } else {
    container.replaceChildren(up, icon("storage"), pathLabel(folderPath));
  }
}

function replaceResults(container, next) {
  const focused = container.contains(document.activeElement) ? document.activeElement.dataset.entry : null;
  const scroll = container.querySelector(".table-scroll")?.scrollLeft || 0;
  container.replaceChildren(next);
  if (scroll) container.querySelector(".table-scroll")?.scrollTo(scroll, 0);
  if (focused) container.querySelector("[data-entry='" + focused + "']")?.focus({preventScroll: true});
}

function renderResults() {
  if (!config?.root) return;
  if (view.section === "storage") {
    renderChart(loaded?.storage?.history);
    for (const key of ["recent", "folders", "largest"]) rank(key, loaded?.storage?.[key]);
    return;
  }
  const target = $("browser-results");
  if (!target) return;
  if ($("query-info")) $("query-info").textContent = view.query ? "Results for “" + view.query + "”" : "";
  renderFolderPath(loaded?.folder);
  target.setAttribute("aria-busy", String(!loaded));
  if (view.section === "search" && !view.query && !view.format) {
    target.replaceChildren(empty("search", "Find a file or folder", "Enter a name or choose a file type to search."));
    return;
  }
  if (!loaded) {
    target.replaceChildren(empty("loading", view.query ? "Searching the index" : "Loading indexed files"));
    return;
  }
  if (!loaded.items?.length) {
    const text = view.query || view.format ? "Try a different name or file type." : "Items appear here as they are indexed.";
    target.replaceChildren(empty(view.section === "map" ? "map" : "files",
      indexing() ? "Waiting for the first results" : "No items found", text));
    return;
  }
  if (view.section === "map") replaceResults(target, renderMap(loaded.items));
  else replaceResults(target, renderTable(loaded.items, loaded.more));
}

function renderTable(entries, more) {
  const result = node("div", "results");
  const viewport = node("div", "table-scroll");
  const table = node("table");
  table.setAttribute("aria-label", sections[view.section][0] + " results");
  const headings = node("tr");
  for (const [field, label] of Object.entries(labels)) {
    const cell = node("th");
    cell.scope = "col";
    const active = view.sort === field;
    if (active) cell.setAttribute("aria-sort", view.ascending ? "ascending" : "descending");
    cell.append(button(label + (active ? (view.ascending ? " ↑" : " ↓") : ""), null, () => {
      updateView({sort: field, ascending: active ? !view.ascending : field === "name", offset: 0}, true);
    }, ""));
    headings.append(cell);
  }
  const thead = node("thead");
  thead.append(headings);
  const body = node("tbody");
  for (const entry of entries) {
    const row = node("tr");
    const name = node("td");
    const control = node("button", "file-link");
    control.dataset.entry = entry.id;
    control.type = "button";
    control.append(icon(entry.folder ? "folders" : "file"), entryName(entry, view.section !== "folders"));
    control.addEventListener("click", () => openEntry(entry, control));
    name.append(control);
    const onDisk = node("td", "number", formatBytes(entry.allocated, entry.estimated));
    if (entry.estimated) onDisk.title = "Estimated disk space";
    row.append(name, onDisk, node("td", "number", formatBytes(entry.logical)),
      node("td", "number", entry.modified ? date.format(entry.modified * 1000) : "—"));
    body.append(row);
  }
  table.append(thead, body);
  viewport.append(table);
  const footer = node("div", "result-bar");
  const pagination = node("div");
  const prev = button("Previous page", "left", () => updateView({offset: Math.max(0, view.offset - 150)}), "square");
  const next = button("Next page", "right", () => updateView({offset: view.offset + 150}), "square");
  prev.disabled = view.offset === 0;
  next.disabled = !more;
  pagination.append(prev, next);
  footer.append(node("span", "number", "Items " + numbers.format(view.offset + 1) + "–" + numbers.format(view.offset + entries.length)), pagination);
  result.append(viewport, footer);
  return result;
}

function splitTiles(items, x, y, width, height, add) {
  if (items.length === 1) {
    add(items[0], x, y, width, height);
    return;
  }
  const total = items.reduce((sum, item) => sum + item.weight, 0);
  let sum = items[0].weight;
  let cut = 1;
  while (cut < items.length - 1 && Math.abs(total / 2 - sum - items[cut].weight) < Math.abs(total / 2 - sum)) {
    sum += items[cut].weight;
    cut += 1;
  }
  const share = sum / total;
  if (width * 1.7 >= height) {
    const size = width * share;
    splitTiles(items.slice(0, cut), x, y, size, height, add);
    splitTiles(items.slice(cut), x + size, y, width - size, height, add);
  } else {
    const size = height * share;
    splitTiles(items.slice(0, cut), x, y, width, size, add);
    splitTiles(items.slice(cut), x, y + size, width, height - size, add);
  }
}

function renderMap(entries) {
  const panel = node("div");
  const tiles = entries.filter((entry) => entry.allocated > 0).slice(0, 24)
    .map((entry) => ({entry, weight: Math.pow(entry.allocated, .8)}));
  if (!tiles.length) return empty("map", "Nothing to map", "This folder has no indexed items using disk space.");
  const map = node("section", "map");
  map.setAttribute("aria-label", "Largest items in this folder");
  const largest = tiles[0].weight;
  splitTiles(tiles, 0, 0, 100, 100, (item, x, y, width, height) => {
    const entry = item.entry;
    const tile = node("button", "tile");
    tile.type = "button";
    tile.dataset.entry = entry.id;
    const label = node("span", "tile-name");
    label.append(icon(entry.folder ? "folders" : "file"), node("span", "", entry.name));
    const size = formatBytes(entry.allocated, entry.estimated);
    tile.append(label, node("span", "number", size));
    tile.title = entry.name + " · " + size;
    tile.setAttribute("aria-label", tile.title);
    Object.assign(tile.style, {left: x + "%", top: y + "%", width: width + "%", height: height + "%",
      background: mapColors[Math.round(Math.pow(item.weight / largest, .33) * (mapColors.length - 1))]});
    tile.addEventListener("click", () => openEntry(entry, tile));
    map.append(tile);
  });
  const legend = node("div", "map-legend");
  const scale = node("div", "swatches");
  scale.setAttribute("aria-hidden", "true");
  for (const color of mapColors) {
    const swatch = node("span");
    swatch.style.background = color;
    scale.append(swatch);
  }
  legend.append("Smaller", scale, "Larger", "·", "Showing up to 24 items");
  panel.append(map, legend);
  return panel;
}

function showMessage(message, retry, reason = "action") {
  const box = $("message");
  if (box.dataset.reason === reason && box.querySelector("span")?.textContent === message && !box.hidden) return;
  box.dataset.reason = reason;
  box.replaceChildren(icon("info"), node("span", "", message));
  box.append(retry ? button("Try again", null, () => {
    clearMessage();
    send("retry");
    if (config?.root) loadView(true);
  }) : button("Dismiss message", "close", clearMessage, "square"));
  box.hidden = false;
}

function clearMessage() {
  $("message").hidden = true;
  delete $("message").dataset.reason;
}

function openPreview(entry, trigger) {
  previewEntry = entry;
  previewTrigger = trigger;
  $("preview-name").textContent = entry.name;
  $("preview-path").textContent = entry.path;
  $("preview-path").title = entry.path;
  $("preview-stage").replaceChildren(node("span", "muted", "Loading preview…"));
  $("preview").showModal();
  $("close-preview").focus();
  previewToken += 1;
  send("preview", {id: entry.id, token: previewToken});
}

function bindDialog(dialog, close) {
  $(close).append(icon("close"));
  $(close).addEventListener("click", () => $(dialog).close());
}

bindDialog("settings", "close-settings");
bindDialog("preview", "close-preview");
const settingsButton = $("settings-button");
settingsButton.append(icon("settings"), node("span", "", "Settings"));
settingsButton.setAttribute("aria-label", "Settings");
settingsButton.title = "Settings";
settingsButton.addEventListener("click", () => {
  if (!config) return;
  $("settings-location").textContent = config.root || "No location selected";
  $("settings-location").title = config.root || "";
  $("change-location-note").hidden = !config.root;
  $("startup-setting").checked = config.startup;
  $("settings").showModal();
  $("close-settings").focus();
});
$("settings").addEventListener("close", () => settingsButton.focus());
$("change-location").addEventListener("click", () => {
  $("settings").close();
  send("scan", {drive: false, startup: config.root ? config.startup : setupStartup});
});
$("startup-setting").addEventListener("change", (event) => send("startup", {enabled: event.target.checked}));
$("preview-reveal").addEventListener("click", () => {
  if (previewEntry) send("reveal", {id: previewEntry.id});
  $("preview").close();
});
$("preview").addEventListener("close", () => {
  if (previewTrigger?.isConnected) previewTrigger.focus({preventScroll: true});
  previewEntry = null;
  previewToken += 1;
});

document.addEventListener("keydown", (event) => {
  if (document.querySelector("dialog[open]")) return;
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f" && config?.root) {
    event.preventDefault();
    if ($("query")) $("query").focus();
    else go(freshView("search"), true);
  } else if (event.altKey && ["ArrowLeft", "ArrowRight"].includes(event.key)) {
    event.preventDefault();
    changeHistory(event.key === "ArrowLeft" ? -1 : 1);
  }
});
document.addEventListener("pointerup", (event) => {
  if (event.button === 3 || event.button === 4) {
    event.preventDefault();
    historyShortcut(event.button === 3 ? -1 : 1);
  }
});

window.SpaceTrail = {
  receive(event, data) {
    switch (event) {
      case "config": {
        const sameRoot = config && config.root === data.root;
        config = data;
        $("startup-setting").checked = config.startup;
        if (!sameRoot) {
          clearMessage();
          status = {phase: data.root ? "starting" : "loading", indexed: 0, processed: 0, blocked: 0, capacity: null};
          view = freshView("storage");
          stack = [view];
          position = 0;
          if (config.root) showView();
          else renderScreen();
        }
        break;
      }
      case "status":
        status = data;
        renderStatus();
        break;
      case "data":
        if (data.id === serial) {
          loaded = data;
          if ($("message").dataset.reason === "query") clearMessage();
          renderResults();
        }
        break;
      case "error":
        showMessage(data.message, data.retry, data.reason);
        break;
      case "readable":
        if ($("message").dataset.reason === "query") clearMessage();
        break;
      case "preview": {
        if (!$("preview").open || previewToken !== data.token) break;
        const stage = $("preview-stage");
        if (data.image) {
          const image = node("img");
          image.alt = "Preview of " + previewEntry.name;
          image.src = data.image;
          stage.replaceChildren(image);
        } else {
          stage.replaceChildren(node("p", "muted", "Windows has no preview for this file."));
        }
        break;
      }
    }
  },
  history: historyShortcut,
};

renderScreen();
send("ready");
