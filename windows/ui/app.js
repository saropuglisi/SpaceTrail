(() => {
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
  files: ["Files", "Browse all indexed files."],
  folders: ["Folders", "Browse your disks and compare folder sizes."],
  search: ["Search", "Find files and folders across the index."],
  map: ["Map", "Explore the files and folders that take up the most space."],
  storage: ["Storage", "See disk usage and which files are taking up more space."],
};

const formats = [
  ["", "Any file type"], ["pdf", "PDF"], ["image", "Images"], ["video", "Videos"],
  ["audio", "Audio"], ["document", "Documents"], ["ebook", "Books"],
  ["archive", "Archives"], ["installer", "Installers"],
];
const largeFileMinimum = 100_000_000;
const fileSizes = [0, 10_000_000, largeFileMinimum, 1_000_000_000, 10_000_000_000];
const phases = {
  starting: "Preparing",
  scanning: "Scanning",
  updating: "Updating",
  current: "Indexed",
  paused: "Paused",
  unavailable: "Unavailable",
};

const labels = {name: "Name", disk: "On disk", logical: "File size", modified: "Modified"};
const numbers = new Intl.NumberFormat("en");
const date = new Intl.DateTimeFormat("en", {month: "short", day: "numeric", year: "numeric"});
const chartDate = new Intl.DateTimeFormat("en", {month: "short", day: "numeric"});
const chartTime = new Intl.DateTimeFormat("en", {hour: "numeric", minute: "2-digit"});
const mapColors = ["#303c5b", "#3c4b77", "#4b5087", "#5c4b8f", "#6c4993", "#82509a"];

const freshView = (section) => ({
  section, folder: null, query: "", format: "", minimum_file_bytes: 0,
  hide_system: true, sort: "disk", ascending: false,
  drive: null, history_drive: null, offsets: {}, pageOffsets: [{}], days: 7,
});
let view = freshView("files");
let stack = [view];
let position = 0;
let serial = 0;
let config = null;
let savingStartup = false;
let loaded = null;
let status = {scope: "all_drives", drives: [], paused: false};
let previewToken = 0;
let previewEntry = null;
let previewTrigger = null;
let groupsRecentGrowthByFolder = false;
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
  const {pageOffsets, ...request} = view;
  send("view", {...request, id: serial});
}

function go(next, focusQuery = false) {
  if (!config) return;
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

function showView(focusQuery = false, focusHeading = true) {
  loaded = null;
  $("main").scrollTo(0, 0);
  renderScreen();
  loadView();
  if (focusQuery) $("query")?.focus();
  else if (focusHeading) $("page-title")?.focus({preventScroll: true});
}

function updateView(changes, keepContent = false) {
  view = {...view, ...changes};
  stack[position] = view;
  loadView(keepContent);
}

function openEntry(entry, trigger) {
  if (entry.folder) {
    go({...freshView(view.section === "map" ? "map" : "folders"), drive: entry.drive, folder: entry.id});
  } else {
    openPreview(entry, trigger);
  }
}

const entryKey = (entry) => entry.drive + ":" + entry.id;
const isScanning = (drive) => drive.phase === "starting" || drive.phase === "scanning";
const indexing = () => status.drives.some(isScanning);
const isBrowsing = () => view.section === "folders" || view.section === "map";

function renderNavigation() {
  $("navigation").hidden = !config;
  $("navigation").replaceChildren();
  if (!config) return;
  for (const [key, [label]] of Object.entries(sections)) {
    const control = button(label, key, () => {
      if (view.section !== key) go(freshView(key), key === "search");
    }, "nav-button");
    control.setAttribute("aria-label", label);
    control.title = label;
    if (key === view.section) control.setAttribute("aria-current", "page");
    $("navigation").append(control);
  }
}

function resetPaging(changes) {
  updateView({...changes, offsets: {}, pageOffsets: [{}]});
}

function selectDrive(drive) {
  resetPaging({drive, folder: null, history_drive: null});
}

function renderDrivePicker(select, drives, includeAll, value) {
  const choices = includeAll ? [["", "All drives"]] : [];
  for (const drive of drives) choices.push([drive.id, drive.label]);
  const signature = JSON.stringify(choices);
  if (select.dataset.choices !== signature) {
    select.dataset.choices = signature;
    select.replaceChildren();
    for (const [id, name] of choices) {
      const option = node("option", "", name);
      option.value = id;
      select.append(option);
    }
  }
  select.value = value || choices[0]?.[0] || "";
  select.hidden = status.scope === "folder" || drives.length < 2;
}

function scanBanner() {
  const drives = status.drives;
  if (indexing()) {
    const banner = node("section", "scan-banner");
    banner.setAttribute("aria-labelledby", "scan-title");
    const accessible = drives.filter((drive) => drive.phase !== "unavailable");
    const ready = accessible.filter((drive) => drive.ready).length;
    const heading = node("div", "scan-heading");
    const title = node("h2", "", "First Scan");
    title.id = "scan-title";
    const summary = status.scope === "folder"
      ? "Indexing your selected folder"
      : numbers.format(ready) + " of " + numbers.format(accessible.length) + " drives indexed";
    heading.append(icon("activity"), title, node("span", "scan-summary", summary));
    banner.append(heading, node("p", "scan-copy", "SpaceTrail is finding files in the background. You can browse results as they appear."));
    if (accessible.length > 1) {
      const progress = node("progress", "scan-progress");
      progress.max = accessible.length;
      progress.value = ready;
      progress.setAttribute("aria-label", "Local drives indexed");
      progress.setAttribute("aria-valuetext", summary);
      banner.append(progress);
    }
    const locations = node("ul", "scan-drives");
    for (const drive of drives) {
      const row = node("li");
      const phase = node("span", "scan-phase", phases[drive.phase]);
      if (isScanning(drive)) phase.prepend(node("span", "spinner"));
      row.append(pathLabel(drive.label), phase);
      if (drive.phase !== "unavailable") {
        row.append(node("span", "number count", numbers.format(isScanning(drive) ? drive.processed : drive.indexed)
          + (isScanning(drive) ? " examined" : " files")));
      }
      locations.append(row);
    }
    banner.append(locations);
    return banner;
  }
  const blocked = drives.reduce((sum, drive) => sum + drive.blocked, 0);
  const pending = drives.some((drive) => drive.phase === "updating");
  if (blocked || pending) {
    const banner = node("p", "notice");
    banner.append(icon("info"), node("strong", "", blocked ? "Limited Access" : "Updating Index"),
      node("span", "", blocked
        ? numbers.format(blocked) + (blocked === 1 ? " folder could not be read." : " folders could not be read.")
        : "You can browse previously indexed files."));
    return banner;
  }
  return null;
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
  const toolbar = $("history-actions");
  const back = button("Go back", "left", () => changeHistory(-1), "square");
  const forward = button("Go forward", "right", () => changeHistory(1), "square");
  back.disabled = position === 0;
  forward.disabled = position === stack.length - 1;
  toolbar.replaceChildren(back, forward);
  const screen = $("screen");
  screen.replaceChildren();
  if (!config) {
    screen.append(empty("loading", "Opening SpaceTrail"));
    return;
  }
  const header = node("header", "page-header");
  const heading = node("div");
  const [title, description] = sections[view.section];
  const pageTitle = node("h1", "", title);
  pageTitle.id = "page-title";
  pageTitle.tabIndex = -1;
  const subtitle = node("p", "", description);
  subtitle.id = "page-subtitle";
  heading.append(pageTitle, subtitle);
  const picker = node("select");
  picker.id = "drive-picker";
  picker.setAttribute("aria-label", "Drive");
  picker.addEventListener("change", () => selectDrive(picker.value || null));
  const actions = node("div", "heading-actions");
  actions.append(picker);
  if (view.section === "storage") {
    const find = button("Find Large Files", "search", () => go({
      ...freshView("files"), drive: view.drive, minimum_file_bytes: largeFileMinimum,
    }));
    find.title = "Find files using at least 100 MB on disk";
    actions.append(find);
  }
  header.append(heading, actions);
  const scan = node("div");
  scan.id = "scan-status";
  screen.append(header, scan);
  if (view.section === "storage") renderOverview(screen);
  else renderBrowser(screen);
  renderStatus();
}

function renderOverview(screen) {
  const overview = node("div", "overview");
  const capacity = node("section", "volume-cards");
  capacity.id = "capacity";
  capacity.setAttribute("aria-label", "Drive capacity");
  const history = node("section", "history");
  const head = node("div", "history-head");
  const controls = node("div", "heading-actions");
  const select = node("select");
  select.id = "history-picker";
  select.setAttribute("aria-label", "Drive history");
  select.addEventListener("change", () => updateView({history_drive: select.value}, true));
  const ranges = node("div", "range");
  ranges.setAttribute("role", "group");
  ranges.setAttribute("aria-label", "Storage history and growth range");
  for (const days of [1, 7, 30, 90]) {
    const item = button(days === 1 ? "24 Hours" : days + " Days", null, () => {
      if (view.days !== days) updateView({days}, true);
      ranges.querySelectorAll("button").forEach((value) => value.setAttribute("aria-pressed", String(value === item)));
    }, "");
    item.setAttribute("aria-pressed", String(days === view.days));
    ranges.append(item);
  }
  const chart = node("div");
  chart.id = "chart";
  controls.append(select, ranges);
  head.append(node("h2", "", "Storage History"), controls);
  history.append(head, chart);
  const rankings = node("div", "rankings");
  const groups = node("div", "range");
  groups.setAttribute("role", "group");
  groups.setAttribute("aria-label", "Group Recent Growth By");
  for (const [label, byFolder] of [["Files", false], ["Folders", true]]) {
    const control = button(label, null, () => {
      groupsRecentGrowthByFolder = byFolder;
      for (const peer of groups.querySelectorAll("button")) {
        peer.setAttribute("aria-pressed", String(peer === control));
      }
      renderRecentGrowth();
    }, "");
    control.setAttribute("aria-pressed", String(groupsRecentGrowthByFolder === byFolder));
    groups.append(control);
  }
  const recent = rankingSection("Recent Growth", "", "recent", groups);
  rankings.append(rankingSection("Largest Files", "By disk usage", "largest"),
    rankingSection("Folders to Explore", "One folder per branch", "folders"));
  overview.append(capacity, history, recent, rankings);
  screen.append(overview);
}

function rankingSection(title, subtitle, id, actions) {
  const section = node("section", "rank-section");
  const heading = node("h2", "", title);
  if (actions) {
    const header = node("div", "rank-header");
    header.append(heading, actions);
    section.append(header);
  } else {
    section.append(heading);
  }
  const caption = node("p", "rank-help", subtitle);
  caption.id = id + "-caption";
  const results = node("div");
  results.id = id + "-ranking";
  section.append(caption, results);
  return section;
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

function driveSummary(drive, sidebar = false) {
  const area = node("div", sidebar ? "sidebar-volume" : "capacity");
  const head = node("div", "capacity-heading");
  const label = node("div", "drive-name");
  label.append(icon("storage"), pathLabel(drive.label));
  head.append(label);
  const space = drive.capacity;
  if (space && !sidebar) head.append(node("span", "muted number", formatBytes(space.total) + " total"));
  area.append(head);
  if (space) {
    const detail = node("div", "capacity-info");
    if (!sidebar) detail.append(node("span", "number", formatBytes(space.total - space.free) + " used"));
    detail.append(node("span", "number", formatBytes(space.free) + " free"));
    area.append(meter(space), detail);
  } else {
    area.append(node("p", "capacity-info", "Space unavailable"));
  }
  return area;
}

function shownDrives() {
  return status.drives.filter((drive) => !view.drive || drive.id === view.drive);
}

function renderStatus() {
  if (!config) return;
  const drives = status.drives;
  const sidebar = $("sidebar-drive");
  sidebar.hidden = drives.length === 0;
  const overviewReady = drives.some((drive) => drive.ready);
  let activity = indexing() ? "Indexing" : "Background Updates";
  if (status.paused) activity = "Updates Paused";
  else if (!overviewReady && !indexing()) activity = "Waiting for Drives";
  sidebar.replaceChildren(...drives.map((drive) => driveSummary(drive, true)), node("p", "sidebar-state", activity));

  const picker = $("drive-picker");
  if (picker) renderDrivePicker(picker, drives, !isBrowsing(), view.drive || loaded?.folder?.drive);
  const history = $("history-picker");
  if (history) renderDrivePicker(history, shownDrives(), false, view.history_drive);
  if ($("capacity")) $("capacity").replaceChildren(...shownDrives().map((drive) => driveSummary(drive)));

  const scan = $("scan-status");
  if (scan) {
    const banner = scanBanner();
    scan.replaceChildren(...(banner ? [banner] : []));
  }
  if ($("page-subtitle") && view.section === "files" && drives.length) {
    const count = shownDrives().reduce((sum, drive) => sum + drive.indexed, 0);
    $("page-subtitle").textContent = numbers.format(count) + " files indexed"
      + (!view.drive && drives.length > 1 ? " across " + drives.length + " drives" : "");
  }
  if (status.paused || drives.some((drive) => drive.phase === "paused")) {
    showMessage("Some background updates are paused. You can browse saved results.", true, "broker");
  } else if ($("message").dataset.reason === "broker") {
    clearMessage();
  }
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
  const labelDate = end - start < 86_400 ? chartTime : chartDate;
  const geometry = node("div", "chart");
  const ticks = node("div", "axis-y");
  ticks.setAttribute("aria-hidden", "true");
  ticks.append(node("span", "", formatBytes(high)), node("span", "", formatBytes(low)));
  const graphic = svg("svg", {viewBox: "0 0 600 83", preserveAspectRatio: "none", role: "img",
    "aria-label": "Disk used from " + labelDate.format(start * 1000) + " to " + labelDate.format(end * 1000)
      + ", starting at " + formatBytes(used[0]) + " and ending at " + formatBytes(used.at(-1))});
  for (const y of [1, 41.5, 82]) {
    graphic.append(svg("line", {x1: 0, y1: y, x2: 600, y2: y, stroke: "var(--line)", "vector-effect": "non-scaling-stroke"}));
  }
  const points = history.map((point, index) => {
    const x = (point.hour - start) / (end - start) * 600;
    const y = 78 - (used[index] - low) / (high - low) * 73;
    return x.toFixed(2) + "," + y.toFixed(2);
  }).join(" ");
  graphic.append(svg("polygon", {points: "0,82 " + points + " 600,82", fill: "var(--storage-accent)", opacity: ".13"}));
  graphic.append(svg("polyline", {points, fill: "none", stroke: "var(--storage-accent)", "stroke-width": 2, "vector-effect": "non-scaling-stroke"}));
  const times = node("div", "axis-x");
  times.setAttribute("aria-hidden", "true");
  for (const time of [start, end]) times.append(node("span", "", labelDate.format(time * 1000)));
  geometry.append(ticks, graphic, times);
  container.replaceChildren(geometry);
}

function entryName(entry, includePath) {
  const name = node("span", "rank-name");
  const title = node("strong", "", entry.name);
  title.title = entry.name;
  name.append(title);
  if (includePath) {
    const directory = parentPath(entry.path);
    const count = entry.growing_files;
    const detail = count ? (count === 1 ? "1 file grew" : numbers.format(count) + " files grew") + " · " + directory
      : directory;
    const path = node("small", "path", detail);
    path.title = entry.path;
    name.append(path);
  }
  return name;
}

function rank(container, key, entries) {
  if (!entries?.length) {
    const messages = {
      recent: entries ? "No growth recorded in this period." : "Loading recent growth…",
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
    control.dataset.entry = entryKey(entry);
    const growth = key === "recent" && entry.growth > 0;
    const size = growth ? (entry.estimated ? "≈ " : "") + "+" + formatBytes(entry.growth) : formatBytes(entry.allocated, entry.estimated);
    control.append(icon(entry.folder ? "folders" : "file"), entryName(entry, true),
      node("span", "rank-value number" + (growth ? " growth" : ""), size), icon("right"));
    control.addEventListener("click", () => openEntry(entry, control));
    const item = node("li");
    item.append(control);
    list.append(item);
  }
  replaceResults(container, list);
}

function renderRecentGrowth() {
  $("recent-caption").textContent = groupsRecentGrowthByFolder
    ? "Growth from files in each folder. Subfolders are listed separately."
    : "Files that added the most space.";
  const key = groupsRecentGrowthByFolder ? "recent_folders" : "recent";
  rank($("recent-ranking"), "recent", loaded?.storage?.[key]);
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
    const search = node("button", "button primary", "Search");
    search.type = "submit";
    const input = node("div", "search-group");
    input.append(field, search);
    const controls = node("div", "filter-controls");
    const format = node("select");
    format.setAttribute("aria-label", "File type");
    for (const [value, text] of formats) {
      const option = node("option", "", text);
      option.value = value;
      format.append(option);
    }
    format.value = view.format;
    format.addEventListener("change", () => resetPaging({format: format.value}));
    controls.append(format);
    if (view.section !== "folders") {
      const size = node("select");
      size.setAttribute("aria-label", "Minimum File Size on Disk");
      size.title = "Filter files by the space they use on disk";
      for (const bytes of fileSizes) {
        const option = node("option", "", bytes ? formatBytes(bytes) + "+" : "Any size");
        option.value = bytes;
        size.append(option);
      }
      size.value = view.minimum_file_bytes;
      size.addEventListener("change", () => resetPaging({minimum_file_bytes: Number(size.value)}));
      controls.append(size);
      query.addEventListener("input", renderQueryInfo);
    }
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      resetPaging({query: query.value.trim()});
    });
    form.append(input, controls);
    screen.append(form);
    if (view.section !== "folders") {
      const options = node("div", "file-options");
      const system = node("label", "check");
      const checkbox = node("input");
      checkbox.type = "checkbox";
      checkbox.checked = !view.hide_system;
      checkbox.addEventListener("change", () => resetPaging({hide_system: !checkbox.checked}));
      system.append(checkbox, "Show system files");
      options.append(system);
      const queryInfo = node("span", "path");
      queryInfo.id = "query-info";
      options.append(queryInfo);
      screen.append(options);
    }
  }
  const results = node("div");
  results.id = "browser-results";
  results.setAttribute("aria-live", "polite");
  screen.append(results);
}

function renderFolderPath(folder) {
  const container = $("folder-path");
  if (!container) return;
  const drive = status.drives.find((drive) => drive.id === (folder?.drive || view.drive)) || status.drives[0];
  const folderPath = folder?.path || drive?.path;
  const up = button("Go up one folder", "up", () => {
    go({...freshView(view.section), drive: folder.drive, folder: folder.parent});
  }, "square");
  up.disabled = folder?.parent == null;
  container.replaceChildren(up);
  if (folderPath && folderPath !== drive?.path) {
    const root = button(drive?.label || "Drive root", "storage", () => go({...freshView(view.section), drive: folder.drive}));
    container.append(root, pathLabel(folderPath));
  } else if (drive) {
    container.append(icon("storage"), pathLabel(drive.label));
  }
  if (folder) {
    container.append(button("Show in Explorer", "pin", () => send("reveal", {drive: folder.drive, id: folder.id})));
  }
  if (folder && view.section === "folders") {
    const title = folderPath === drive?.path ? drive.label : folderPath.split("\\").filter(Boolean).at(-1);
    $("page-title").textContent = title || "Folders";
    $("page-title").title = folderPath;
  }
}

function replaceResults(container, next) {
  const focused = container.contains(document.activeElement) ? document.activeElement.dataset.entry : null;
  const scroll = container.querySelector(".table-scroll")?.scrollLeft || 0;
  container.replaceChildren(next);
  if (scroll) container.querySelector(".table-scroll")?.scrollTo(scroll, 0);
  if (focused) container.querySelector("[data-entry='" + focused + "']")?.focus({preventScroll: true});
}

function renderQueryInfo() {
  const info = $("query-info");
  if (!info) return;
  const draft = $("query").value.trim();
  info.textContent = view.query ? "Results for “" + view.query + "”"
    : draft ? "Press Enter to search by name." : "";
}

function renderResults() {
  if (!config) return;
  if (view.section === "storage") {
    renderChart(loaded?.storage?.history);
    renderRecentGrowth();
    for (const kind of ["largest", "folders"]) {
      rank($(kind + "-ranking"), kind, loaded?.storage?.[kind]);
    }
    return;
  }
  const target = $("browser-results");
  if (!target) return;
  renderQueryInfo();
  renderFolderPath(loaded?.folder);
  const drive = $("drive-picker");
  renderDrivePicker(drive, status.drives, !isBrowsing(), view.drive || loaded?.folder?.drive);
  const filtered = view.query || view.format || view.minimum_file_bytes > 0;
  const waitingForInput = view.section === "search" && !filtered;
  target.setAttribute("aria-busy", String(!loaded && !waitingForInput));
  if (waitingForInput) {
    target.replaceChildren(empty("search", "Find a file or folder", "Enter a name or choose a file type or minimum size."));
    return;
  }
  if (!loaded) {
    target.replaceChildren(empty("loading", filtered ? "Searching the index" : "Loading indexed files"));
    return;
  }
  if (!status.drives.length) {
    target.replaceChildren(empty("storage", "No local drives found", "Connect or unlock a local drive to start scanning."));
    return;
  }
  if (shownDrives().length && shownDrives().every((drive) => drive.phase === "unavailable")) {
    target.replaceChildren(empty("storage", "Drive unavailable", "Unlock or reconnect the drive to continue."));
    return;
  }
  if (!loaded.items?.length) {
    const text = view.minimum_file_bytes ? "Try a smaller minimum size or a different filter."
      : filtered ? "Try a different name or file type." : "Items appear here as they are indexed.";
    target.replaceChildren(empty(view.section === "map" ? "map" : "files",
      indexing() ? "Waiting for the first results" : "No items found", text));
    return;
  }
  if (view.section === "map") replaceResults(target, renderMap(loaded.items));
  else replaceResults(target, renderTable(loaded.items, loaded.next));
}

function renderTable(entries, nextOffsets) {
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
      resetPaging({sort: field, ascending: active ? !view.ascending : field === "name"});
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
    control.dataset.entry = entryKey(entry);
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
  const previousPages = view.pageOffsets;
  const prev = button("Previous page", "left", () => {
    const pages = previousPages.slice(0, -1);
    updateView({offsets: pages.at(-1), pageOffsets: pages});
  }, "square");
  const next = button("Next page", "right", () => {
    updateView({offsets: nextOffsets, pageOffsets: [...previousPages, nextOffsets]});
  }, "square");
  prev.disabled = previousPages.length === 1;
  next.disabled = !nextOffsets;
  pagination.append(prev, next);
  const start = (previousPages.length - 1) * 150;
  footer.append(node("span", "number", "Items " + numbers.format(start + 1) + "–" + numbers.format(start + entries.length)), pagination);
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
    tile.dataset.entry = entryKey(entry);
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
    if (config) loadView(true);
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
  $("preview-folder").hidden = entry.parent == null;
  $("preview-stage").replaceChildren(node("span", "muted", "Loading preview…"));
  $("preview").showModal();
  $("close-preview").focus();
  previewToken += 1;
  send("preview", {drive: entry.drive, id: entry.id, token: previewToken});
}

function bindDialog(dialog, close) {
  $(close).append(icon("close"));
  $(close).addEventListener("click", () => $(dialog).close());
}

bindDialog("settings", "close-settings");
bindDialog("preview", "close-preview");
const settingsButton = $("settings-button");
settingsButton.append(icon("settings"));
const searchButton = $("search-button");
searchButton.append(icon("search"));
searchButton.addEventListener("click", () => {
  if (view.section === "search") $("query")?.focus();
  else go(freshView("search"), true);
});

function updateSettings() {
  const location = $("settings-location");
  location.textContent = status.scope === "folder" ? status.drives[0]?.path || "Selected folder" : "All local drives";
  location.title = location.textContent;
  $("all-drives").hidden = status.scope !== "folder";
  $("startup-setting").value = config.startup;
}

settingsButton.addEventListener("click", () => {
  if (!config) return;
  updateSettings();
  $("settings").showModal();
  $("close-settings").focus();
});
$("settings").addEventListener("close", () => settingsButton.focus());
for (const [id, all_drives] of [["all-drives", true], ["change-location", false]]) {
  $(id).addEventListener("click", () => {
    $("settings").close();
    send("scan", {all_drives});
  });
}
const startupPrompt = $("startup-prompt");
function saveStartup(mode) {
  if (savingStartup) return;
  savingStartup = true;
  send("startup", {mode});
}

$("startup-setting").addEventListener("change", (event) => saveStartup(event.target.value));
$("skip-startup").addEventListener("click", () => saveStartup(null));
$("enable-startup").addEventListener("click", () => saveStartup("open"));
startupPrompt.addEventListener("cancel", (event) => {
  event.preventDefault();
  saveStartup(null);
});
startupPrompt.addEventListener("close", () => $("main").focus({preventScroll: true}));
$("preview-reveal").addEventListener("click", () => {
  if (previewEntry) send("reveal", {drive: previewEntry.drive, id: previewEntry.id});
  $("preview").close();
});
$("preview-folder").addEventListener("click", () => {
  if (previewEntry?.parent == null) return;
  const {drive, parent} = previewEntry;
  $("preview").close();
  go({...freshView("folders"), drive, folder: parent});
});
$("preview").addEventListener("close", () => {
  if (previewTrigger?.isConnected) previewTrigger.focus({preventScroll: true});
  previewEntry = null;
  previewToken += 1;
});

document.addEventListener("keydown", (event) => {
  if (document.querySelector("dialog[open]")) return;
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f" && config) {
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
        const first = config === null;
        config = data;
        savingStartup = false;
        updateSettings();
        if (first) {
          showView(false, false);
          if (data.offer_startup) startupPrompt.showModal();
        }
        const error = data.startup_error ? "Could not save your sign-in choice. " + data.startup_error : "";
        $("startup-prompt-error").textContent = startupPrompt.open ? error : "";
        $("startup-settings-error").textContent = startupPrompt.open ? "" : error;
        if (startupPrompt.open && !data.offer_startup && !error) startupPrompt.close();
        break;
      }
      case "scope_changed":
        status = {scope: "all_drives", drives: [], paused: false};
        clearMessage();
        view = freshView("files");
        stack = [view];
        position = 0;
        showView(false, false);
        break;
      case "status": {
        const topologyChanged = status.drives.map((drive) => drive.id).join(",")
          !== data.drives.map((drive) => drive.id).join(",");
        status = data;
        if (view.drive && !status.drives.some((drive) => drive.id === view.drive)) {
          selectDrive(null);
        } else if (view.history_drive && !status.drives.some((drive) => drive.id === view.history_drive)) {
          updateView({history_drive: null}, true);
        } else if (topologyChanged && view.pageOffsets.length > 1) {
          resetPaging({});
        }
        renderStatus();
        break;
      }
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
})();
