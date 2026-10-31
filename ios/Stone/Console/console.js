/* Stone's console page, started from OCX's (ollama tech-note e459e9b7bc,
   artifact aa7b17fd1b). Stone answers each tool from the clones on the phone
   (ConsoleBridge in RepoWebView.swift); the tools and the card format are
   the contract shared with OCX, not this code. */

/* Every tool answers JSON; a failure is {stopped: WHY}, never a rejection. */
function tool(name, input) {
  const ocx = window.webkit?.messageHandlers?.ocx;
  if (!ocx) return Promise.resolve({stopped: "The console runs inside Stone."});
  return ocx.postMessage({tool:name, input}).then(JSON.parse);
}

const viewer = new URLSearchParams(location.search).get("for");
const conversation = document.getElementById("conversation");
const topics = document.getElementById("topics");
const menu = document.getElementById("m");
let cards = [];

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text != null) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function asOf(answer, parent) {
  if (answer.as_of) parent.append(element("small", "as of " + answer.as_of, "as-of"));
}

function milestone(item, parent) {
  const row = element("div", null, "milestone");
  row.append(itemLink(item));
  row.append(element("span", item.due, "due"));
  parent.append(row);
}

function drawGreeting(summary, milestones) {
  conversation.replaceChildren();
  const message = element("section", null, "msg");
  message.append(element("h1", "Hello."));
  const glance = element("div", null, "glance");
  for (const card of cards) {
    message.append(element("p", card.say));
    glance.append(element("span", card.count + " " + card.title, "pill"));
  }
  message.append(glance);
  if (milestones?.items?.length) {
    const rows = element("div", null, "ms");
    for (const item of milestones.items) milestone(item, rows);
    message.append(rows);
    asOf(milestones, message);
  } else {
    asOf(summary, message);
  }
  if (summary.stopped) message.append(element("p", summary.stopped));
  conversation.append(message);
}

function itemLink(item) {
  /* Every move to a record goes through open: Stone switches to that clone's view. */
  const link = element("button", item.title, "item");
  link.type = "button";
  link.addEventListener("click", () => tool("open", {project:item.project, hash:item.hash}));
  return link;
}

function drawCard(answer) {
  conversation.replaceChildren();
  const message = element("section", null, "msg");
  message.append(element("h1", answer.title || answer.name || "Topic"));
  if (answer.say) message.append(element("p", answer.say));
  if (answer.stopped) message.append(element("p", answer.stopped));
  const items = element("ul", null, "items");
  for (const item of answer.items || []) {
    const row = element("li");
    row.append(itemLink(item));
    const details = [item.project, item.time, item.due].filter(Boolean);
    row.append(element("small", details.join(" · "), "meta"));
    items.append(row);
  }
  message.append(items);
  asOf(answer, message);
  conversation.append(message);
}

function drawTopics() {
  topics.replaceChildren();
  const all = element("a", "Everything");
  all.href = "#";
  topics.append(all);
  for (const card of cards) {
    const link = element("a", card.title + " · " + card.count);
    link.href = "#topic=" + encodeURIComponent(card.project) + "/" + encodeURIComponent(card.name);
    topics.append(link);
  }
}

/* A card is named by its project and its name: #topic=PROJECT/NAME. */
function selectedTopic() {
  const fragment = location.hash.slice(1);
  if (!fragment.startsWith("topic=")) return null;
  const [project, name] = fragment.slice(6).split("/").map(decodeURIComponent);
  return name ? {project, name} : null;
}

let summary;
let milestones;
async function showSelection() {
  menu.checked = false;
  const topic = selectedTopic();
  for (const link of topics.querySelectorAll("a")) {
    if (link.hash === location.hash || (!topic && link.hash === "")) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  if (!topic) return drawGreeting(summary, milestones);
  try {
    drawCard(await tool("card", {project:topic.project, name:topic.name, for:viewer}));
  } catch (error) {
    conversation.replaceChildren(element("p", error.message));
  }
}

async function start() {
  try {
    summary = await tool("cards", {for:viewer});
    cards = summary.cards || [];
    drawTopics();
    /* Milestones are the items that carry a due date, from any card. */
    const answers = await Promise.all(cards.filter(card => card.count > 0).map(card => tool("card", {project:card.project, name:card.name, for:viewer})));
    const due = answers.flatMap(answer => (answer.items || []).filter(item => item.due));
    milestones = due.length ? {items:due, as_of:summary.as_of} : null;
    await showSelection();
  } catch (error) {
    conversation.replaceChildren(element("p", error.message));
  }
}

window.addEventListener("hashchange", showSelection);
start();
