"use strict";
(() => {
  // src/webview/shim.ts
  var page = {};
  globalThis.browser = {
    runtime: {
      onMessage: {
        addListener: (listener) => {
          page.handle = listener;
        }
      },
      sendMessage: async () => false,
      getFrameId: () => -1
    }
  };

  // src/content/flat.ts
  var skippedTags = /* @__PURE__ */ new Set([
    "head",
    "script",
    "style",
    "noscript",
    "template",
    "link",
    "meta"
  ]);
  function flatParent(element) {
    let parent = element.assignedSlot ?? element.parentNode;
    if (parent instanceof ShadowRoot) return parent.host;
    return parent instanceof Element ? parent : null;
  }
  function flatChildren(node) {
    if (node instanceof Element && node.shadowRoot)
      return Array.from(node.shadowRoot.childNodes);
    if (node instanceof HTMLSlotElement) {
      let assigned = node.assignedNodes();
      return assigned.length ? assigned : Array.from(node.childNodes);
    }
    return Array.from(node.childNodes);
  }
  var modal;
  function openModal() {
    if (modal === void 0) {
      modal = document.querySelector(":modal");
      setTimeout(() => modal = void 0);
    }
    return modal;
  }
  function outsideModal(element) {
    let blocking = openModal();
    if (!blocking || element.contains(blocking)) return false;
    for (let node = element; node; node = flatParent(node))
      if (node === blocking) return false;
    return true;
  }
  function isPruned(element) {
    if (skippedTags.has(element.localName)) return true;
    if (element.getAttribute("aria-hidden") === "true" || element.hasAttribute("inert"))
      return true;
    if (element.hidden === true) return true;
    if (outsideModal(element)) return true;
    if (!element.checkVisibility())
      return getComputedStyle(element).display !== "contents";
    return isFlattened(getComputedStyle(element));
  }
  function isFlattened(style2) {
    if (style2.scale.split(/\s+/).some((token) => parseFloat(token) === 0))
      return true;
    let matrix = style2.transform.match(/^matrix(3d)?\(([^)]+)\)$/);
    if (!matrix) return false;
    let values = matrix[2].split(",").map(Number);
    let [a, b, c, d] = matrix[1] ? [values[0], values[1], values[4], values[5]] : values;
    return a * d - b * c === 0;
  }
  var isInvisible = (element) => /^(hidden|collapse)$/.test(getComputedStyle(element).visibility);
  var isShown = (element) => !isPruned(element) && !isInvisible(element);
  var isBlock = (element) => !/^(inline|contents|$)/.test(getComputedStyle(element).display);
  var spacing = [
    "margin-left",
    "margin-right",
    "padding-left",
    "padding-right",
    "border-left-width",
    "border-right-width"
  ];
  var spaced = (style2) => spacing.some((property) => parseFloat(style2.getPropertyValue(property)) > 0);
  function setsApart(element) {
    if (isBlock(element) || spaced(getComputedStyle(element))) return true;
    return ["::before", "::after"].some((pseudo) => {
      let style2 = getComputedStyle(element, pseudo);
      if (/^(none|normal|)$/.test(style2.content) || style2.display === "none")
        return false;
      return spaced(style2) || parseFloat(style2.width) > 0;
    });
  }
  function* flatElements(root) {
    for (let child of flatChildren(root)) {
      if (!(child instanceof Element) || isPruned(child)) continue;
      if (!isInvisible(child)) yield child;
      yield* flatElements(child);
    }
  }

  // src/shared/redact.ts
  var hidden = "[hidden]";
  var wordsOf = (name) => name.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2").toLowerCase().split(/[^a-z0-9]+/).filter((word) => word !== "");
  var secretWords = /* @__PURE__ */ new Set([
    "token",
    "secret",
    "password",
    "passwd",
    "pwd",
    "pass",
    "passcode",
    "key",
    "apikey",
    "sig",
    "signature",
    "auth",
    "authorization",
    "credential",
    "credentials",
    "session",
    "sessionid",
    "sid",
    "jwt",
    "otp",
    "oob",
    "ticket",
    "assertion",
    "bearer",
    "verifier",
    "saml",
    "samlresponse"
  ]);
  var secretEndings = [
    "token",
    "secret",
    "password",
    "signature",
    "apikey",
    "sessid",
    "sessionid"
  ];
  function isSecretParameter(name) {
    let decoded = name;
    try {
      decoded = decodeURIComponent(name);
    } catch {
    }
    let words = wordsOf(decoded);
    let joined = words.join("");
    if (joined === "code") return true;
    return words.some((word) => secretWords.has(word)) || secretEndings.some((ending) => joined.endsWith(ending));
  }
  function redactUrl(url) {
    return url.replace(
      /^([a-z][a-z0-9+.-]*:)?\/\/[^/?#]*@/i,
      (_match, scheme) => `${scheme ?? ""}//${hidden}@`
    ).replace(
      /([?&#;])([^=?&#;]*)=([^?&#;]*)/g,
      (match, separator, name, value) => value && isSecretParameter(name) ? `${separator}${name}=${hidden}` : match
    );
  }

  // src/content/sensitive.ts
  var secretAutocomplete = /* @__PURE__ */ new Set([
    "current-password",
    "new-password",
    "one-time-code",
    "cc-number",
    "cc-csc"
  ]);
  var exemptTypes = /* @__PURE__ */ new Set([
    "checkbox",
    "radio",
    "button",
    "submit",
    "reset",
    "image",
    "file",
    "hidden",
    "range",
    "color",
    "date",
    "time",
    "datetime-local",
    "month",
    "week"
  ]);
  var unhintedTypes = /* @__PURE__ */ new Set(["email", "search"]);
  var secretWords2 = /* @__PURE__ */ new Set([
    "password",
    "passwd",
    "pwd",
    "pass",
    "passcode",
    "passphrase",
    "pin",
    "otp",
    "totp",
    "mfa",
    "2fa",
    "cvv",
    "cvv2",
    "cvc",
    "csc",
    "ssn",
    "iban",
    "secret",
    "token",
    "apikey"
  ]);
  var secretRuns = [
    "password",
    "passcode",
    "passphrase",
    "apikey",
    "privatekey",
    "accesskey",
    "cardnumber",
    "ccnumber",
    "ccnum",
    "creditcard",
    "securitycode",
    "verificationcode",
    "onetimecode",
    "socialsecurity"
  ];
  var secretEndings2 = ["secret", "token"];
  var hintMax = 256;
  var wasPassword = /* @__PURE__ */ new WeakSet();
  function isSecretHint(hint) {
    let words = wordsOf(hint.slice(0, hintMax));
    let joined = words.join("");
    let pin = words.findIndex((word) => word === "pin");
    if (pin >= 0 && words[pin + 1] === "code") words.splice(pin, 1);
    return words.some((word) => secretWords2.has(word)) || secretRuns.some((run) => joined.includes(run)) || secretEndings2.some((ending) => joined.endsWith(ending));
  }
  function isSensitive(element) {
    let input = element instanceof HTMLInputElement ? element : null;
    let editable = element instanceof HTMLTextAreaElement || element instanceof HTMLElement && element.isContentEditable;
    if (!input && !editable) return false;
    let type = input?.type ?? "";
    if (type === "password") wasPassword.add(element);
    if (wasPassword.has(element)) return true;
    if (exemptTypes.has(type)) return false;
    let autocomplete = (element.getAttribute("autocomplete") ?? "").toLowerCase().split(/\s+/);
    if (autocomplete.some((token) => secretAutocomplete.has(token))) return true;
    if (unhintedTypes.has(type)) return false;
    let labels = input?.labels ?? element.labels ?? [];
    let hints = [
      element.getAttribute("name"),
      element.id,
      element.getAttribute("aria-label"),
      element.getAttribute("placeholder"),
      element.getAttribute("title"),
      ...Array.from(labels, (label) => label.textContent)
    ];
    return hints.some((hint) => hint && isSecretHint(hint));
  }

  // src/content/describe.ts
  var inputRoles = {
    button: "button",
    submit: "button",
    reset: "button",
    image: "button",
    checkbox: "checkbox",
    radio: "radio",
    range: "slider",
    number: "spinbutton",
    search: "searchbox",
    color: "button",
    file: "button"
  };
  var tagRoles = {
    button: "button",
    summary: "button",
    textarea: "textbox",
    option: "option",
    h1: "heading",
    h2: "heading",
    h3: "heading",
    h4: "heading",
    h5: "heading",
    h6: "heading",
    p: "paragraph",
    img: "img",
    nav: "navigation",
    main: "main",
    header: "banner",
    footer: "contentinfo",
    aside: "complementary",
    article: "article",
    form: "form",
    dialog: "dialog",
    ul: "list",
    ol: "list",
    menu: "list",
    li: "listitem",
    dl: "list",
    dt: "term",
    dd: "definition",
    table: "table",
    tr: "row",
    td: "cell",
    th: "columnheader",
    fieldset: "group",
    details: "group",
    hr: "separator",
    progress: "progressbar",
    meter: "meter",
    iframe: "iframe",
    frame: "iframe",
    blockquote: "blockquote",
    pre: "code",
    code: "code",
    svg: "img"
  };
  var contentRoles = /* @__PURE__ */ new Set([
    "button",
    "link",
    "heading",
    "tab",
    "menuitem",
    "menuitemcheckbox",
    "menuitemradio",
    "option",
    "treeitem",
    "cell",
    "gridcell",
    "columnheader",
    "rowheader",
    "checkbox",
    "radio",
    "switch",
    "tooltip",
    "term"
  ]);
  var authorRoles = /* @__PURE__ */ new Set([
    "alertdialog",
    "dialog",
    "form",
    "grid",
    "listbox",
    "menu",
    "menubar",
    "radiogroup",
    "region",
    "tabpanel",
    "table",
    "tablist",
    "toolbar",
    "tree",
    "treegrid"
  ]);
  var nameMax = 80;
  var svgTitle = (element) => element.localName === "svg" ? element.querySelector(":scope > title")?.textContent?.trim() : "";
  var formTags = /* @__PURE__ */ new Set(["input", "select", "textarea"]);
  function contentText(node, parts, budget) {
    let hidden2;
    for (let child of flatChildren(node)) {
      if (budget.left <= 0) return;
      if (child.nodeType === Node.TEXT_NODE) {
        hidden2 ??= node instanceof Element && isInvisible(node);
        if (hidden2) continue;
        let text2 = child.textContent ?? "";
        parts.push(text2);
        budget.left -= text2.length;
        continue;
      }
      if (!(child instanceof Element)) continue;
      if (child.localName === "br") {
        parts.push(" ");
        continue;
      }
      if (isPruned(child) || formTags.has(child.localName)) continue;
      if (isInvisible(child)) {
        contentText(child, parts, budget);
        continue;
      }
      let label = child.getAttribute("aria-label")?.trim() || (child.localName === "img" ? child.getAttribute("alt")?.trim() : "") || svgTitle(child);
      if (label) {
        parts.push(` ${label} `);
        budget.left -= label.length;
        continue;
      }
      let gap2 = isBlock(child) ? " " : "";
      let start = parts.length;
      parts.push(gap2);
      contentText(child, parts, budget);
      let title = child.getAttribute("title")?.trim();
      if (title && !parts.slice(start).join("").trim()) parts.push(` ${title} `);
      parts.push(gap2);
    }
  }
  var shownText = (element) => {
    let parts = [];
    contentText(element, parts, { left: nameMax * 8 });
    return collapse(parts.join(""));
  };
  function collapse(text2, max = nameMax) {
    let clean = (text2 ?? "").slice(0, max * 8).replace(/\s+/g, " ").trim();
    return clean.length > max ? `${clean.slice(0, max - 3)}...` : clean;
  }
  var isEditableRoot = (element) => element.isContentEditable && !flatParent(element)?.isContentEditable;
  var isField = (node) => node instanceof Element && (formTags.has(node.localName) || isEditableRoot(node) && isSensitive(node));
  function roleOf(element) {
    let explicit = element.getAttribute("role")?.trim().split(/\s+/)[0];
    if (explicit) return explicit;
    let tag = element.localName;
    if (tag === "a" || tag === "area")
      return element.hasAttribute("href") ? "link" : "generic";
    if (tag === "input")
      return inputRoles[element.type] ?? "textbox";
    if (tag === "select")
      return element.multiple || element.size > 1 ? "listbox" : "combobox";
    if ((tag === "header" || tag === "footer") && element.parentElement?.closest(
      "article, aside, main, nav, section, [role=article], [role=complementary], [role=main], [role=navigation], [role=region]"
    ))
      return "generic";
    if (tagRoles[tag]) return tagRoles[tag];
    if (isEditableRoot(element)) return "textbox";
    return "generic";
  }
  function labelledByText(element) {
    let ids = element.getAttribute("aria-labelledby")?.trim().split(/\s+/) ?? [];
    let root = element.getRootNode();
    return ids.map((id) => root.getElementById(id)).filter((target2) => target2 !== null).map(
      (target2) => target2.getAttribute("aria-label")?.trim() || shownText(target2) || collapse(target2.textContent)
    ).join(" ");
  }
  function nameOf(element, fromContent = true) {
    let input = element;
    let isTextField = element.localName === "textarea" || isEditableRoot(element) || element.localName === "input" && !inputRoles[input.type];
    let candidates = [
      () => labelledByText(element),
      () => element.getAttribute("aria-label"),
      () => "labels" in input && input.labels ? [...new Set(Array.from(input.labels, shownText))].join(" ") : "",
      () => element.localName === "input" && inputRoles[input.type] === "button" && input.type !== "file" ? input.value || input.alt : "",
      () => element.localName === "img" ? element.getAttribute("alt") : "",
      () => svgTitle(element),
      () => element.localName === "fieldset" ? element.querySelector(":scope > legend")?.textContent : "",
      () => element.localName === "table" ? element.querySelector(":scope > caption")?.textContent : "",
      () => {
        if (!fromContent || isTextField || element.localName === "select")
          return "";
        return shownText(element);
      },
      () => element.getAttribute("title"),
      () => element.getAttribute("placeholder")
    ];
    for (let candidate of candidates) {
      let name = collapse(candidate());
      if (name) return name;
    }
    return "";
  }
  function describe(target2) {
    if (!target2) return "null";
    if (target2 === window) return "window";
    if (target2 === document) return "document";
    if (!(target2 instanceof Element)) return target2.constructor.name;
    let id = target2.id ? `#${target2.id}` : "";
    let className = typeof target2.className === "string" ? target2.className.trim().split(/\s+/)[0] : "";
    let isPageRoot = target2 === document.body || target2 === document.documentElement;
    let text2 = isPageRoot ? "" : collapse(target2.textContent, 24);
    return `${target2.localName}${id}${className ? `.${className}` : ""}${text2 ? ` "${text2}"` : ""}`;
  }

  // src/main/network.ts
  var takeEvent = "safaripilot-network-take";
  var pendingEvent = "safaripilot-network-pending";
  var answerEvent = "safaripilot-network-answer";
  var fetchEvent = "safaripilot-fetch";
  var fetchAnswerEvent = "safaripilot-fetch-answer";
  var maxBody = 1e5;
  var maxFetchBody = 5e6;

  // src/content/network.ts
  var waiting = false;
  var reply;
  var onAnswer = (event) => {
    if (!waiting) return;
    waiting = false;
    reply = event.detail;
  };
  var installNetworkReader = () => window.addEventListener(answerEvent, onAnswer, true);
  var text = (value) => typeof value === "string" ? value.slice(0, maxBody) : null;
  var recordOf = (raw) => ({
    method: String(raw.method),
    url: String(raw.url),
    time: Number(raw.time) || 0,
    requestBody: text(raw.requestBody),
    status: typeof raw.status === "number" ? raw.status : null,
    contentType: String(raw.contentType ?? ""),
    responseBody: text(raw.responseBody),
    truncated: raw.truncated === true,
    note: text(raw.note)
  });
  function ask(type, detail) {
    installNetworkReader();
    waiting = true;
    reply = void 0;
    window.dispatchEvent(
      new CustomEvent(type, { detail: JSON.stringify(detail) })
    );
    waiting = false;
    return typeof reply === "string" ? reply : void 0;
  }
  function pendingSince(since) {
    let count = Number(ask(pendingEvent, { since }));
    return Number.isInteger(count) && count >= 0 ? count : null;
  }
  function takeBody(url, method, time) {
    let answer = ask(takeEvent, { url, method, time });
    if (answer === void 0) return { ok: true, capturing: false, record: null };
    let parsed = JSON.parse(answer);
    return {
      ok: true,
      capturing: true,
      record: parsed === null ? null : recordOf(Object(parsed))
    };
  }

  // src/content/refs.ts
  var nextRef = 1 + Math.floor(Math.random() * 1e3) * 1e3;
  var refsByElement = /* @__PURE__ */ new WeakMap();
  var elementsByRef = /* @__PURE__ */ new Map();
  function existingRef(element) {
    return refsByElement.get(element) ?? null;
  }
  function refFor(element) {
    let known = refsByElement.get(element);
    if (known !== void 0) return known;
    let ref2 = nextRef++;
    refsByElement.set(element, ref2);
    elementsByRef.set(ref2, new WeakRef(element));
    return ref2;
  }
  function resolveRef(ref2) {
    let weak = elementsByRef.get(ref2);
    if (!weak)
      return { ok: false, error: `ref ${ref2} is unknown`, code: "stale_ref" };
    let element = weak.deref();
    if (!element) {
      elementsByRef.delete(ref2);
      return {
        ok: false,
        error: `ref ${ref2} is gone (element was garbage collected)`,
        code: "stale_ref"
      };
    }
    if (!element.isConnected)
      return {
        ok: false,
        error: `ref ${ref2} is detached from the document`,
        code: "stale_ref"
      };
    return element;
  }
  function pruneRefs() {
    for (let [ref2, weak] of elementsByRef) {
      if (!weak.deref()) elementsByRef.delete(ref2);
    }
  }

  // src/content/geometry.ts
  var round = (value) => Math.round(value * 100) / 100;
  function toRect(box) {
    return {
      left: round(box.left),
      top: round(box.top),
      width: round(box.width),
      height: round(box.height)
    };
  }
  var hasArea = (box) => box.width > 0 && box.height > 0;
  function boxOf(element) {
    let box = element.getBoundingClientRect();
    if (hasArea(box) || !(element instanceof HTMLInputElement) || !/^(checkbox|radio)$/.test(element.type))
      return box;
    for (let label of element.labels ?? []) {
      let labelBox = label.getBoundingClientRect();
      if (hasArea(labelBox)) return labelBox;
    }
    return box;
  }
  function readViewport() {
    let visual = window.visualViewport;
    return {
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      devicePixelRatio: window.devicePixelRatio,
      visualScale: visual.scale,
      visualOffsetLeft: visual.offsetLeft,
      visualOffsetTop: visual.offsetTop,
      visualWidth: visual.width,
      visualHeight: visual.height,
      clientWidth: document.documentElement.clientWidth,
      clientHeight: document.documentElement.clientHeight
    };
  }
  function visibleArea(viewport) {
    return {
      left: viewport.visualOffsetLeft,
      top: viewport.visualOffsetTop,
      width: viewport.visualWidth,
      height: viewport.visualHeight
    };
  }
  function intersect(first, second) {
    let left = Math.max(first.left, second.left);
    let top = Math.max(first.top, second.top);
    let right = Math.min(first.left + first.width, second.left + second.width);
    let bottom = Math.min(first.top + first.height, second.top + second.height);
    if (right - left < 1 || bottom - top < 1) return null;
    return { left, top, width: right - left, height: bottom - top };
  }
  var fractions = [0.5, 0.25, 0.75, 0.1, 0.9];
  function unite(first, second) {
    if (second.width <= 0 || second.height <= 0) return first;
    if (first.width <= 0 || first.height <= 0) return second;
    let left = Math.min(first.left, second.left);
    let top = Math.min(first.top, second.top);
    let right = Math.max(first.left + first.width, second.left + second.width);
    let bottom = Math.max(first.top + first.height, second.top + second.height);
    return { left, top, width: right - left, height: bottom - top };
  }
  function candidatePoints(rect, clip2) {
    let insetLeft = Math.min(2, clip2.width / 4);
    let insetTop = Math.min(2, clip2.height / 4);
    let clampLeft = (value) => Math.min(
      Math.max(value, clip2.left + insetLeft),
      clip2.left + clip2.width - insetLeft
    );
    let clampTop = (value) => Math.min(
      Math.max(value, clip2.top + insetTop),
      clip2.top + clip2.height - insetTop
    );
    let center = {
      left: clampLeft(rect.left + rect.width / 2),
      top: clampTop(rect.top + rect.height / 2)
    };
    let grid = fractions.flatMap(
      (columnFraction) => fractions.map((rowFraction) => ({
        left: clampLeft(clip2.left + clip2.width * columnFraction),
        top: clampTop(clip2.top + clip2.height * rowFraction)
      }))
    );
    let distance = (point) => Math.hypot(point.left - center.left, point.top - center.top);
    grid.sort((first, second) => distance(first) - distance(second));
    return [center, ...grid].map((point) => ({
      left: round(point.left),
      top: round(point.top)
    }));
  }
  function pickPoint(rect, clip2, hits) {
    return candidatePoints(rect, clip2).find(hits) ?? null;
  }

  // src/content/hit.ts
  function deepElementFromPoint(point) {
    let hit = document.elementFromPoint(point.left, point.top);
    while (hit?.shadowRoot) {
      let inner = hit.shadowRoot.elementFromPoint(point.left, point.top);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    return hit;
  }
  function isWithin(target2, node) {
    while (node) {
      if (node === target2) return true;
      node = node instanceof ShadowRoot ? node.host : node.assignedSlot ?? node.parentNode;
    }
    return false;
  }

  // src/content/frames.ts
  var identities = [
    "matrix(1,0,0,1,0,0)",
    "matrix3d(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1)"
  ];
  var isFrameHost = (element) => element instanceof HTMLIFrameElement || element instanceof HTMLElement && element.localName === "frame";
  function frameIdOf(iframe) {
    try {
      return browser.runtime.getFrameId(iframe);
    } catch {
      return -1;
    }
  }
  var blocksScripts = (iframe) => iframe instanceof HTMLIFrameElement && iframe.hasAttribute("sandbox") && !iframe.sandbox.contains("allow-scripts");
  var inlineSchemes = ["data:", "blob:", "javascript:"];
  function sourceOf(iframe) {
    if (iframe.hasAttribute("srcdoc")) return "srcdoc";
    if (!iframe.src) return "about:blank";
    let scheme = URL.canParse(iframe.src) ? new URL(iframe.src).protocol : "";
    return inlineSchemes.includes(scheme) ? scheme : iframe.src;
  }
  var tokens = (value) => value.trim().split(/\s+/);
  var amount = (token) => parseFloat(token) / (token.endsWith("%") ? 100 : 1);
  var stillValues = {
    transform: (value) => identities.includes(value.replace(/\s+/g, "")),
    translate: (value) => tokens(value).every((token) => amount(token) === 0),
    scale: (value) => tokens(value).every((token) => amount(token) === 1),
    rotate: (value) => amount(tokens(value).at(-1)) === 0
  };
  function isTransformed(iframe, bounds) {
    let scaled = (shown2, laidOut) => laidOut > 0 && Math.abs(shown2 - laidOut) > Math.max(1, laidOut * 0.01);
    if (scaled(bounds.width, iframe.offsetWidth) || scaled(bounds.height, iframe.offsetHeight))
      return true;
    for (let node = iframe; node; node = flatParent(node)) {
      let style2 = getComputedStyle(node);
      let moves = Object.entries(stillValues).some(([property, still]) => {
        let value = style2.getPropertyValue(property);
        return value !== "" && value !== "none" && !still(value);
      });
      if (moves) return true;
    }
    return false;
  }
  function contentBox(iframe, bounds) {
    let style2 = getComputedStyle(iframe);
    let px = (value) => parseFloat(value) || 0;
    let left = px(style2.paddingLeft);
    let top = px(style2.paddingTop);
    return toRect(
      new DOMRect(
        bounds.left + iframe.clientLeft + left,
        bounds.top + iframe.clientTop + top,
        iframe.clientWidth - left - px(style2.paddingRight),
        iframe.clientHeight - top - px(style2.paddingBottom)
      )
    );
  }
  function frameEntry(iframe) {
    let bounds = iframe.getBoundingClientRect();
    let box = contentBox(iframe, bounds);
    return {
      ref: refFor(iframe),
      frameId: frameIdOf(iframe),
      src: sourceOf(iframe),
      sandbox: iframe.getAttribute("sandbox"),
      box,
      clip: intersect(box, visibleArea(readViewport())),
      transformed: isTransformed(iframe, bounds)
    };
  }
  function listFrames() {
    let frames = [...flatElements(document)].filter(isFrameHost).map(frameEntry);
    return {
      ok: true,
      url: location.href,
      title: document.title,
      viewport: readViewport(),
      frames
    };
  }
  function iframeFor(ref2) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    if (!isFrameHost(element))
      return {
        ok: false,
        error: `ref ${ref2} is a <${element.localName}>, not an iframe`,
        code: "invalid_argument"
      };
    return element;
  }
  var inside = (inner, outer) => inner.left >= outer.left && inner.top >= outer.top && inner.left + inner.width <= outer.left + outer.width && inner.top + inner.height <= outer.top + outer.height;
  function frameBox(ref2, reveal) {
    let iframe = iframeFor(ref2);
    if (!isFrameHost(iframe)) return iframe;
    let before = frameEntry(iframe);
    if (!reveal || inside(before.box, visibleArea(readViewport())))
      return {
        ok: true,
        frame: before,
        moved: false,
        viewport: readViewport(),
        origin: performance.timeOrigin
      };
    iframe.scrollIntoView({
      block: "nearest",
      inline: "nearest",
      behavior: "instant"
    });
    let after = frameEntry(iframe);
    return {
      ok: true,
      frame: after,
      moved: after.box.left !== before.box.left || after.box.top !== before.box.top,
      viewport: readViewport(),
      origin: performance.timeOrigin
    };
  }
  function hitFrame(ref2, points) {
    let iframe = iframeFor(ref2);
    if (!isFrameHost(iframe)) return iframe;
    let hits = points.map((point) => deepElementFromPoint(point) === iframe);
    let first = points[0] ? deepElementFromPoint(points[0]) : null;
    return { ok: true, hits, hitDescription: describe(first) };
  }

  // src/content/scroll.ts
  var scrollableOverflow = /* @__PURE__ */ new Set(["auto", "scroll", "overlay"]);
  function canScroll(node, left, top) {
    let style2 = getComputedStyle(node);
    let across = left !== 0 && scrollableOverflow.has(style2.overflowX) && node.scrollWidth > node.clientWidth;
    let down = top !== 0 && scrollableOverflow.has(style2.overflowY) && node.scrollHeight > node.clientHeight;
    return across || down;
  }
  function scrollTarget(element, left, top) {
    let page2 = document.scrollingElement ?? document.documentElement;
    for (let node = element; node && node !== page2; node = flatParent(node)) {
      if (canScroll(node, left, top)) return node;
    }
    return page2;
  }
  function scroll(ref2, left, top) {
    let element = ref2 === null ? null : resolveRef(ref2);
    if (element !== null && !(element instanceof Element)) return element;
    let target2 = scrollTarget(element, left, top);
    let before = [target2.scrollLeft, target2.scrollTop];
    target2.scrollBy({ left, top, behavior: "instant" });
    let moved = target2.scrollLeft !== before[0] || target2.scrollTop !== before[1];
    let page2 = document.scrollingElement ?? document.documentElement;
    if (target2 === page2) return { ok: true, moved, viewport: readViewport() };
    let container = { left: target2.scrollLeft, top: target2.scrollTop };
    return { ok: true, moved, viewport: readViewport(), container };
  }
  function scrollIntoView(ref2) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    let before = element.getBoundingClientRect();
    element.scrollIntoView({
      block: "center",
      inline: "nearest",
      behavior: "instant"
    });
    let after = element.getBoundingClientRect();
    let moved = before.left !== after.left || before.top !== after.top;
    return { ok: true, moved, viewport: readViewport() };
  }

  // src/content/snapshot.ts
  var interactiveTags = /* @__PURE__ */ new Set(["button", "select", "textarea", "summary"]);
  var widgetRoles = /* @__PURE__ */ new Set([
    "button",
    "link",
    "checkbox",
    "radio",
    "switch",
    "tab",
    "menuitem",
    "menuitemcheckbox",
    "menuitemradio",
    "option",
    "textbox",
    "searchbox",
    "combobox",
    "listbox",
    "slider",
    "spinbutton",
    "treeitem"
  ]);
  var clickHandlers = [
    "onclick",
    "ondblclick",
    "oncontextmenu",
    "onmousedown",
    "onmouseup",
    "onpointerdown"
  ];
  function isInteractive(element) {
    let tag = element.localName;
    if (tag === "input") return element.type !== "hidden";
    if (isWidget(element)) return true;
    let tabIndex = element.getAttribute("tabindex");
    if (tabIndex !== null && tabIndex.trim() !== "-1") return true;
    if (clickHandlers.some(
      (handler) => element.hasAttribute(handler) || element[handler]
    ))
      return true;
    if (isEditableRoot(element)) return true;
    if (element.getAttribute("draggable") === "true") return true;
    let control = tag === "label" ? element.control : null;
    if (control && isShown(control)) return false;
    if (isScroller(element)) return true;
    if (getComputedStyle(element).cursor !== "pointer") return false;
    let parent = flatParent(element);
    if (parent && getComputedStyle(parent).cursor === "pointer") return false;
    for (let ancestor = parent; ancestor; ancestor = flatParent(ancestor)) {
      if (isWidget(ancestor)) return false;
    }
    return true;
  }
  var isScroller = (element) => element !== document.scrollingElement && element !== document.body && canScroll(element, 1, 1);
  function isWidget(element) {
    let tag = element.localName;
    if (interactiveTags.has(tag) || tag === "input") return true;
    if (tag === "a" && element.hasAttribute("href")) return true;
    return widgetRoles.has(
      element.getAttribute("role")?.trim().split(/\s+/)[0] ?? ""
    );
  }
  function hasBox(element) {
    let box = boxOf(element);
    return box.width > 0 && box.height > 0;
  }
  function elementInfo(element, visible, name = nameOf(element)) {
    let rect = toRect(boxOf(element));
    let info = {
      ref: refFor(element),
      tag: element.localName,
      role: roleOf(element),
      name,
      rect,
      inViewport: intersect(rect, visible) !== null
    };
    if (element.disabled === true || element.getAttribute("aria-disabled") === "true")
      info.disabled = true;
    return info;
  }
  function snapshot() {
    pruneRefs();
    let viewport = readViewport();
    let visible = visibleArea(viewport);
    let elements = [];
    for (let element of flatElements(document)) {
      if (!isInteractive(element) || !hasBox(element)) continue;
      elements.push(elementInfo(element, visible));
    }
    return {
      ok: true,
      url: location.href,
      title: document.title,
      viewport,
      elements
    };
  }

  // src/content/tree.ts
  var leafTags = /* @__PURE__ */ new Set([
    "input",
    "textarea",
    "select",
    "img",
    "svg",
    "iframe",
    "frame",
    "video",
    "audio",
    "canvas",
    "progress",
    "meter",
    "hr"
  ]);
  var collapsibleRoles = /* @__PURE__ */ new Set(["generic", "none", "presentation"]);
  var textInputTypes = /* @__PURE__ */ new Set([
    "text",
    "email",
    "search",
    "url",
    "tel",
    "password",
    "number",
    "range",
    "date",
    "datetime-local",
    "month",
    "week",
    "time",
    "color"
  ]);
  var textMax = 300;
  var range = document.createRange();
  var valueMax = 40;
  var hrefMax = 60;
  function inView(view, box) {
    let { clip: clip2 } = view;
    if (intersect(toRect(box), clip2)) return true;
    if (box.width <= 0 || box.height <= 0) return false;
    let bottom = clip2.top + clip2.height;
    view.above = Math.max(view.above, clip2.top - box.top);
    view.below = Math.max(view.below, box.bottom - bottom);
    return false;
  }
  var clipping = /^(hidden|clip|auto|scroll)$/;
  function clips(element) {
    if (element === document.body || element === document.documentElement)
      return false;
    let style2 = getComputedStyle(element);
    return clipping.test(style2.overflowX) || clipping.test(style2.overflowY);
  }
  function pushText(items, text2) {
    let last = items.at(-1);
    if (last && "text" in last) {
      last.text = `${last.text}${text2}`.replace(/\s+/g, " ");
      return;
    }
    items.push({ text: text2 });
  }
  function gap(items) {
    let last = items.at(-1);
    if (last && "text" in last && !last.text.endsWith(" ")) last.text += " ";
  }
  function splice(items, child, children) {
    let block = setsApart(child);
    if (block) gap(items);
    for (let item of children) {
      if ("text" in item) pushText(items, item.text);
      else items.push(item);
    }
    if (block) gap(items);
  }
  function add(items, child, walk) {
    let interactiveOnly = walk.interactiveOnly;
    if (child.nodeType === Node.TEXT_NODE) {
      let raw = child.textContent ?? "";
      let text2 = interactiveOnly ? "" : collapse(raw, textMax);
      if (!text2) {
        if (/\s/.test(raw)) gap(items);
        return;
      }
      if (walk.view) {
        range.selectNodeContents(child);
        if (!inView(walk.view, range.getBoundingClientRect())) return;
      }
      pushText(
        items,
        `${/^\s/.test(raw) ? " " : ""}${text2}${/\s$/.test(raw) ? " " : ""}`
      );
      walk.left -= text2.length + 2;
      return;
    }
    if (!(child instanceof Element)) return;
    if (child.localName === "br") {
      gap(items);
      return;
    }
    walk.nodes -= 1;
    if (isPruned(child)) return;
    if (isInvisible(child)) {
      splice(items, child, build(child, walk));
      return;
    }
    let view = walk.view;
    let box = view ? boxOf(child) : null;
    let outside = view ? !inView(view, box) : false;
    let clip2 = view?.clip;
    if (view && !outside && clips(child))
      view.clip = intersect(view.clip, toRect(box));
    let children = leafTags.has(child.localName) || isEditableRoot(child) ? [] : build(child, walk, outside);
    if (view) view.clip = clip2;
    if (outside && !children.some((item) => "element" in item)) return;
    let role = roleOf(child);
    let interactive = isInteractive(child);
    let hostsFrame = isFrameHost(child) && frameIdOf(child) >= 0;
    if (hostsFrame && view) {
      let content = contentBox(child, box);
      let visible = intersect(content, view.clip);
      view.frames.set(
        child,
        visible && {
          ...visible,
          left: visible.left - content.left,
          top: visible.top - content.top
        }
      );
    }
    let elements = children.filter((item) => "element" in item).length;
    let wraps = !contentRoles.has(role) && elements > 0;
    let name = nameOf(child, interactive && !wraps && !authorRoles.has(role));
    let wrapsOne = collapsibleRoles.has(role) && !name && elements === 1;
    let shown2 = wrapsOne ? false : hostsFrame || (interactiveOnly ? interactive : interactive || (role === "img" ? name !== "" : !collapsibleRoles.has(role) || child.hasAttribute("aria-label") || child.hasAttribute("aria-labelledby")));
    let control = child.control;
    if (control && isShown(control))
      children = children.filter((item) => !("text" in item));
    let named = { legend: "fieldset", caption: "table" }[child.localName];
    if (named && child.parentElement?.localName === named) return;
    if (!shown2) {
      splice(items, child, children);
      return;
    }
    let fromContent = interactive || contentRoles.has(role);
    if (fromContent && name)
      children = children.filter((item) => !("text" in item));
    if (!name && children.length === 1 && "text" in children[0]) {
      name = collapse(children[0].text, textMax);
      children = [];
    }
    if (!interactive && !name && !children.length && !leafTags.has(child.localName))
      return;
    let only = children.length === 1 ? children[0] : null;
    if (interactive && only && "element" in only && only.name === name && isInteractive(only.element)) {
      items.push(only);
      return;
    }
    items.push({ element: child, role, name, children });
    walk.left -= role.length + name.length + 8;
  }
  function rootItems(walk) {
    let root = document.body ?? document.documentElement;
    if (!isEditableRoot(root)) return build(root, walk);
    let items = [];
    add(items, root, walk);
    return items;
  }
  function build(node, walk, outside = false) {
    let items = [];
    let hidden2;
    for (let child of flatChildren(node)) {
      if (walk.left <= 0 || walk.nodes <= 0) break;
      if (child.nodeType === Node.TEXT_NODE) {
        hidden2 ??= outside || node instanceof Element && isInvisible(node);
        if (hidden2) continue;
      }
      add(items, child, walk);
    }
    return items;
  }
  function valueOf(element) {
    let tag = element.localName;
    if (tag === "select")
      return Array.from(
        element.selectedOptions,
        (option) => option.text
      ).join(", ");
    if (tag === "textarea") return element.value;
    if (isEditableRoot(element)) return element.innerText;
    if (tag !== "input") return "";
    let input = element;
    if (input.type === "file")
      return Array.from(input.files ?? [], (file) => file.name).join(", ");
    return textInputTypes.has(input.type) ? input.value : "";
  }
  function shortHref(anchor) {
    let url = new URL(anchor.href, location.href);
    if (!url.protocol.startsWith("http"))
      return collapse(redactUrl(url.href), hrefMax);
    let path = `${url.pathname}${url.search}${url.hash}`;
    return collapse(
      redactUrl(url.origin === location.origin ? path : `${url.host}${path}`),
      hrefMax
    );
  }
  function statesOf(element, role) {
    let states = [];
    let html = element;
    let aria = (name) => element.getAttribute(`aria-${name}`);
    if (role === "heading") {
      let level = aria("level") ?? element.localName.match(/^h([1-6])$/)?.[1];
      if (level) states.push(`level=${level}`);
    }
    if (html.checked === true || aria("checked") === "true")
      states.push("checked");
    if (aria("checked") === "mixed") states.push("mixed");
    if (html.disabled === true || aria("disabled") === "true")
      states.push("disabled");
    let details = element.parentElement;
    let expanded = aria("expanded") ?? (element.localName === "summary" && details instanceof HTMLDetailsElement ? String(details.open) : null);
    if (expanded === "true") states.push("expanded");
    if (expanded === "false") states.push("collapsed");
    if (aria("selected") === "true" || element instanceof HTMLOptionElement && element.selected)
      states.push("selected");
    if (aria("pressed") === "true") states.push("pressed");
    if (aria("current") && aria("current") !== "false") states.push("current");
    if (role !== "textbox" && isScroller(element)) states.push("scrollable");
    let sort = aria("sort");
    if (sort && sort !== "none") states.push(`sort=${sort}`);
    if (html.required === true || aria("required") === "true")
      states.push("required");
    if (element instanceof HTMLInputElement && element.type === "file") {
      states.push("type=file");
      if (element.multiple) states.push("multiple");
      if (element.accept) states.push(`accept=${JSON.stringify(element.accept)}`);
    }
    let lines = valueOf(element).split("\n").map((line) => line.replace(/\s+/g, " ").trim()).join("\n").replace(/^\n+/, "");
    let value = lines.length > valueMax ? `${lines.slice(0, valueMax - 3)}...` : lines;
    if (value)
      states.push(
        `value=${isSensitive(element) ? hidden : JSON.stringify(value)}`
      );
    if (element instanceof HTMLAnchorElement && element.hasAttribute("href"))
      states.push(`href=${shortHref(element)}`);
    if (isFrameHost(element)) {
      let source = sourceOf(element);
      let host2 = URL.canParse(source) ? new URL(source).host : "";
      if (host2) states.push(`host=${host2}`);
      if (source === "srcdoc") states.push(source);
      if (blocksScripts(element)) states.push("sandboxed");
      if (frameIdOf(element) < 0) states.push("(frame not loaded)");
    }
    return states;
  }
  function emit(output, line) {
    let next = output.length + (output.lines.length ? 1 : 0) + line.length;
    if (next > output.maxChars) return false;
    output.lines.push(line);
    output.length = next;
    return true;
  }
  var headOf = (role, name) => name ? `${role} ${JSON.stringify(name)}` : role;
  var quoted = (text2) => JSON.stringify(collapse(text2, textMax));
  function render(items, depth, output) {
    let indent = "  ".repeat(depth);
    for (let item of items) {
      if ("text" in item) {
        if (!emit(output, `${indent}${quoted(item.text)}`)) return false;
        continue;
      }
      let { element, role, name, children } = item;
      let states = statesOf(element, role).map((state) => ` ${state}`);
      let ref2 = refFor(element);
      let line = `${indent}${headOf(role, name)} [ref=${output.prefix}${ref2}]${states.join("")}`;
      if (!emit(output, line)) return false;
      let frameId = isFrameHost(element) ? frameIdOf(element) : -1;
      if (frameId >= 0)
        output.frames.push({
          ref: ref2,
          frameId,
          line: output.lines.length - 1,
          depth,
          width: element.clientWidth,
          height: element.clientHeight,
          clip: output.view?.frames.get(element) ?? null
        });
      if (depth + 1 >= output.maxDepth) continue;
      if (!render(children, depth + 1, output)) return false;
    }
    return true;
  }
  var newWalk = (filter, maxChars, maxDepth) => ({
    interactiveOnly: filter === "interactive",
    left: Number.isFinite(maxDepth) ? Infinity : maxChars * 3,
    nodes: Infinity
  });
  var newOutput = (maxChars, maxDepth, prefix) => ({ lines: [], length: 0, maxChars, maxDepth, prefix, frames: [] });
  function linesOf(items, prefix) {
    let output = newOutput(Infinity, Infinity, prefix);
    render(items, 0, output);
    return output.lines;
  }
  function textOf(items, walk, maxChars, maxDepth, prefix) {
    let output = { ...newOutput(maxChars, maxDepth, prefix), view: walk.view };
    let complete = render(items, 0, output);
    return {
      text: output.lines.join("\n"),
      truncated: !complete || walk.left <= 0,
      frames: output.frames
    };
  }
  function readPage(filter, maxChars, ref2, depth, prefix, viewport, clip2) {
    pruneRefs();
    let walk = newWalk(filter, maxChars, depth ?? Infinity);
    let items = [];
    if (viewport)
      walk.view = {
        clip: clip2 ?? visibleArea(readViewport()),
        above: 0,
        below: 0,
        frames: /* @__PURE__ */ new Map()
      };
    if (ref2 === null) items = rootItems(walk);
    if (ref2 !== null) {
      let element = resolveRef(ref2);
      if (!(element instanceof Element)) return element;
      add(items, element, walk);
    }
    return {
      ok: true,
      url: location.href,
      title: document.title,
      viewport: readViewport(),
      ...textOf(items, walk, maxChars, depth ?? Infinity, prefix),
      above: walk.view ? Math.round(walk.view.above) : null,
      below: walk.view ? Math.round(walk.view.below) : null
    };
  }

  // src/content/changes.ts
  var maxElements = 2e4;
  var quietMs = 100;
  var unchangedMs = 1e3;
  var pollMs = 20;
  var abandonMs = 6e4;
  var wasMax = 80;
  var old = (text2) => JSON.stringify(collapse(text2, wasMax));
  var watch = null;
  function adopt(items, parent, nodes) {
    for (let item of items) {
      if ("text" in item) {
        parent.texts.push(item.text.trim());
        continue;
      }
      let { element, role, name } = item;
      let states = statesOf(element, role);
      let value = states.some((state) => state.startsWith("value=")) ? valueOf(element) : null;
      let node = {
        element,
        item,
        role,
        name,
        states,
        value,
        texts: [],
        children: []
      };
      nodes.set(element, node);
      parent.children.push(node);
      adopt(item.children, node, nodes);
    }
  }
  function snapshot2() {
    let walk = { interactiveOnly: false, left: Infinity, nodes: maxElements };
    let items = rootItems(walk);
    if (walk.nodes <= 0) return null;
    let root = {
      element: null,
      item: null,
      role: "",
      name: "",
      states: [],
      value: null,
      texts: [],
      children: []
    };
    let tree = { root, nodes: /* @__PURE__ */ new Map() };
    adopt(items, tree.root, tree.nodes);
    return tree;
  }
  var observed = {
    subtree: true,
    childList: true,
    attributes: true,
    characterData: true
  };
  function observe(root, state) {
    if (root === document || root instanceof ShadowRoot) {
      state.observer.observe(root, observed);
      state.roots.add(root);
    }
    if (root instanceof Element && root.shadowRoot)
      observe(root.shadowRoot, state);
    if (!("querySelectorAll" in root)) return;
    for (let element of root.querySelectorAll("*")) {
      if (element.shadowRoot) observe(element.shadowRoot, state);
    }
  }
  var animationsOf = (state) => [...state.roots].flatMap((root) => root.getAnimations());
  function finishStarted(state) {
    if (document.visibilityState !== "hidden") return;
    for (let animation of animationsOf(state)) {
      if (state.animations.has(animation) || animation.playState === "finished")
        continue;
      if (animation.effect?.getComputedTiming().endTime === Infinity) continue;
      state.animations.add(animation);
      animation.finish();
    }
  }
  function stop() {
    watch?.observer.disconnect();
    watch = null;
  }
  function note(records, state) {
    if (records.some((record2) => record2.attributeName !== "style"))
      state.changed = Date.now();
    for (let record2 of records) {
      for (let node of record2.addedNodes) {
        observe(node, state);
        state.inserted.add(node);
      }
      if (veils.has(record2.attributeName) && !veiled(record2.target))
        state.unveiled.add(record2.target);
    }
  }
  function startDiff() {
    stop();
    let started = Date.now();
    let state = {
      started,
      changed: started,
      before: snapshot2(),
      observer: new MutationObserver((records) => note(records, state)),
      roots: /* @__PURE__ */ new Set(),
      animations: /* @__PURE__ */ new Set(),
      unveiled: /* @__PURE__ */ new Set(),
      inserted: /* @__PURE__ */ new WeakSet(),
      modal: openModal()
    };
    if (state.before) {
      observe(document, state);
      state.animations = new Set(animationsOf(state));
    }
    watch = state;
    setTimeout(() => watch === state && stop(), abandonMs);
    return { ok: true, tooLarge: state.before === null };
  }
  var header = (node, out) => node.element ? `in ${headOf(node.role, node.name)} [ref=${out.prefix}${refFor(node.element)}]:` : out.prefix ? `in iframe ${out.prefix.slice(0, -1)}:` : "in page:";
  function emit2(out, kind, context, line) {
    if (!out.kinds.has(kind)) return;
    out[kind]++;
    let lines = context === out.context || !context.element && !out.prefix && !out.lines.length ? [line] : [header(context, out), line];
    let length = out.length + lines.reduce((sum, text2) => sum + text2.length + 1, 0);
    if (out.full || length - 1 > out.maxChars) {
      out.full = true;
      out.omitted++;
      return;
    }
    out.lines.push(...lines);
    out.length = length;
    out.context = context;
  }
  var statesText = (node) => node.states.map((state) => ` ${state}`).join("");
  var same = (before, after) => before.role === after.role && before.name === after.name && before.value === after.value && before.states.join(" ") === after.states.join(" ");
  var keyOf = (state) => ({ collapsed: "expanded", mixed: "checked" })[state] ?? state.split("=")[0];
  function was(before, after) {
    let parts = [];
    if (before.role !== after.role) parts.push(before.role);
    if (before.name !== after.name)
      parts.push(before.name ? old(before.name) : "no name");
    let prior = new Map(before.states.map((state) => [keyOf(state), state]));
    let now = new Map(after.states.map((state) => [keyOf(state), state]));
    for (let [key, state] of now) {
      let was2 = prior.get(key);
      let valueChanged = key === "value" && before.value !== after.value;
      if (was2 === state && !valueChanged) continue;
      parts.push(was2 ?? (state.includes("=") ? `no ${key}` : `not ${state}`));
    }
    for (let [key, state] of prior) {
      if (!now.has(key)) parts.push(state);
    }
    return parts.join(", ");
  }
  function compareTexts(before, after, context, out) {
    if (before.length === after.length) {
      for (let [index, text2] of after.entries()) {
        if (text2 !== before[index])
          emit2(
            out,
            "changed",
            context,
            `~ ${quoted(text2)} (was ${old(before[index])})`
          );
      }
      return;
    }
    let left = [...before];
    for (let text2 of after) {
      let at2 = left.indexOf(text2);
      if (at2 >= 0) left.splice(at2, 1);
      else emit2(out, "added", context, `+ ${quoted(text2)}`);
    }
    for (let text2 of left) emit2(out, "removed", context, `- ${quoted(text2)}`);
  }
  function movedCount(order) {
    let tails = [];
    for (let index of order) {
      let at2 = tails.findIndex((tail) => tail >= index);
      if (at2 < 0) tails.push(index);
      else tails[at2] = index;
    }
    return order.length - tails.length;
  }
  var wordsOf2 = (line) => [
    line.name,
    ...line.texts,
    ...line.children.flatMap(wordsOf2)
  ];
  function sharesHalf(before, after) {
    let left = wordsOf2(before).filter(Boolean);
    let right = wordsOf2(after).filter(Boolean);
    let shared2 = 0;
    for (let word of right) {
      let at2 = left.indexOf(word);
      if (at2 < 0) continue;
      left.splice(at2, 1);
      shared2++;
    }
    return shared2 * 2 >= Math.max(left.length + shared2, right.length);
  }
  var veils = /* @__PURE__ */ new Set(["aria-hidden", "inert"]);
  var veiled = (element) => element.getAttribute("aria-hidden") === "true" || element.hasAttribute("inert");
  var backInView = (element, out) => underAny(element, (node) => out.unveiled.has(node)) || out.freed !== null && !underAny(element, (node) => node === out.freed || out.inserted.has(node));
  var underAny = (element, test) => {
    for (let node = element; node; node = flatParent(node))
      if (test(node)) return true;
    return false;
  };
  function compare(after, before, trees, out) {
    compareTexts(before.texts, after.texts, after, out);
    let gone = before.children.filter(
      (child) => !trees.after.nodes.has(child.element)
    );
    let standIns = /* @__PURE__ */ new Map();
    for (let child of after.children) {
      if (trees.before.nodes.has(child.element)) continue;
      let index = gone.findIndex(
        (old2) => old2.role === child.role && old2.name === child.name && (old2.name !== "" || sharesHalf(old2, child))
      );
      if (index >= 0) standIns.set(child, gone.splice(index, 1)[0]);
    }
    let removed = /* @__PURE__ */ new Map();
    let hidden2 = 0;
    for (let child of gone) {
      if (child.element.isConnected && (underAny(child.element, veiled) || outsideModal(child.element))) {
        hidden2++;
        continue;
      }
      let line = `${headOf(child.role, child.name)}${statesText(child)}`;
      removed.set(line, (removed.get(line) ?? 0) + 1);
    }
    for (let [line, count] of removed) {
      let times = count > 1 ? ` (${count} times)` : "";
      emit2(out, "removed", after, `- ${line}${times}`);
      if (out.kinds.has("removed")) out.removed += count - 1;
    }
    if (hidden2) {
      emit2(
        out,
        "removed",
        after,
        `- ${hidden2} hidden by aria-hidden, inert or a modal dialog, still in the page`
      );
      if (out.kinds.has("removed")) out.removed += hidden2 - 1;
    }
    let priorOf = (child) => trees.before.nodes.get(child.element) ?? standIns.get(child);
    let at2 = new Map(before.children.map((child, index) => [child, index]));
    let order = after.children.flatMap((child) => at2.get(priorOf(child)) ?? []);
    let moved = movedCount(order);
    if (moved)
      emit2(
        out,
        "changed",
        after,
        `~ reordered: ${moved} of ${order.length} children moved`
      );
    let shown2 = 0;
    for (let child of after.children) {
      let prior = priorOf(child);
      if (!prior && backInView(child.element, out)) {
        shown2++;
        continue;
      }
      if (!prior) {
        for (let line of linesOf([child.item], out.prefix))
          emit2(out, "added", after, `+ ${line}`);
        continue;
      }
      if (!same(prior, child))
        emit2(
          out,
          "changed",
          after,
          `~ ${headOf(child.role, child.name)} [ref=${out.prefix}${refFor(child.element)}]${statesText(child)} (was ${was(prior, child)})`
        );
      compare(child, prior, trees, out);
    }
    if (!shown2) return;
    emit2(
      out,
      "added",
      after,
      `+ ${shown2} shown again as aria-hidden, inert or a modal dialog was lifted; read_page shows them`
    );
    if (out.kinds.has("added")) out.added += shown2 - 1;
  }
  async function takeDiff(prefix, waitMs, maxChars) {
    let state = watch;
    let result = {
      ok: true,
      started: state !== null,
      tooLarge: state?.before === null,
      lines: [],
      added: 0,
      changed: 0,
      removed: 0,
      omitted: 0,
      tracked: true,
      pending: 0,
      settled: true
    };
    if (!state?.before) {
      stop();
      return result;
    }
    let deadline = Date.now() + waitMs;
    let watchUntil = Math.min(deadline, state.started + unchangedMs);
    let sleep = (until) => new Promise(
      (resolve) => setTimeout(resolve, Math.max(0, Math.min(pollMs, until - Date.now())))
    );
    while (true) {
      while (true) {
        finishStarted(state);
        let pending = pendingSince(state.started);
        result.tracked = pending !== null;
        result.pending = pending ?? 0;
        result.settled = Date.now() - state.changed >= quietMs && !result.pending;
        if (result.settled || Date.now() >= deadline) break;
        await sleep(deadline);
      }
      note(state.observer.takeRecords(), state);
      let after = snapshot2();
      if (!after) {
        stop();
        return { ...result, tooLarge: true };
      }
      let trees = { before: state.before, after };
      let pass = (kinds, out2) => {
        let next = out2 ?? {
          ...result,
          unveiled: state.unveiled,
          freed: state.modal && openModal() !== state.modal ? state.modal : null,
          inserted: state.inserted,
          lines: [],
          kinds: new Set(kinds),
          prefix,
          maxChars,
          length: 0,
          full: false,
          context: null
        };
        next.kinds = new Set(kinds);
        next.context = null;
        compare(after.root, state.before.root, trees, next);
        return next;
      };
      let out = pass(["added", "changed", "removed"]);
      if (out.omitted) out = pass(["removed"], pass(["added", "changed"]));
      let { lines, added, changed, removed, omitted } = out;
      if (added + changed + removed || Date.now() >= watchUntil) {
        stop();
        return { ...result, lines, added, changed, removed, omitted };
      }
      let seen = state.changed;
      while (state.changed === seen && Date.now() < watchUntil) {
        await sleep(watchUntil);
        finishStarted(state);
      }
    }
  }

  // src/main/console.ts
  var takeEvent2 = "safaripilot-console-take";
  var takeClearEvent = "safaripilot-console-take-clear";
  var entriesEvent = "safaripilot-console-entries";
  var maxText = 2e3;

  // src/content/console.ts
  var levels = /* @__PURE__ */ new Set([
    "log",
    "info",
    "warn",
    "error",
    "debug",
    "exception"
  ]);
  var waiting2 = false;
  var reply2;
  var onEntries = (event) => {
    if (!waiting2) return;
    waiting2 = false;
    reply2 = event.detail;
  };
  var installReader = () => window.addEventListener(entriesEvent, onEntries, true);
  var entryOf = (raw) => ({
    level: levels.has(raw.level) ? raw.level : "log",
    text: String(raw.text).slice(0, maxText + 100),
    time: Number(raw.time) || 0,
    url: String(raw.url),
    source: typeof raw.source === "string" ? raw.source : null
  });
  function takeConsole(onlyErrors, pattern, limit, clear) {
    installReader();
    waiting2 = true;
    reply2 = void 0;
    window.dispatchEvent(new CustomEvent(clear ? takeClearEvent : takeEvent2));
    waiting2 = false;
    if (typeof reply2 !== "string")
      return { ok: true, capturing: false, entries: [], matched: 0, dropped: 0 };
    let parsed = JSON.parse(reply2);
    if (!Array.isArray(parsed.entries))
      throw new Error("the console capture answered without entries");
    let match = pattern === null ? null : new RegExp(pattern, "i");
    let kept = parsed.entries.map((raw) => entryOf(Object(raw))).filter(
      (entry) => (!onlyErrors || entry.level === "error" || entry.level === "exception") && (!match || match.test(entry.text))
    );
    return {
      ok: true,
      capturing: true,
      entries: kept.slice(-limit),
      matched: kept.length,
      dropped: Number(parsed.dropped) || 0
    };
  }

  // src/content/events.ts
  var loggedTypes = [
    "pointerover",
    "pointerdown",
    "pointerup",
    "pointercancel",
    "mouseover",
    "mousedown",
    "mouseup",
    "click",
    "auxclick",
    "dblclick",
    "contextmenu",
    "focusin",
    "focusout",
    "keydown",
    "keypress",
    "keyup",
    "beforeinput",
    "input",
    "change",
    "submit",
    "dragstart",
    "drop",
    "dragend"
  ];
  var armedTypes = [
    "pointermove",
    "mousemove",
    "pointerenter",
    "mouseenter",
    "pointerleave",
    "mouseleave",
    "pointerout",
    "mouseout",
    "drag",
    "dragenter",
    "dragover",
    "dragleave"
  ];
  var capacity = 1500;
  var buffer = [];
  var targets = /* @__PURE__ */ new WeakMap();
  var armed = false;
  var recording = false;
  function record(entry) {
    buffer.push(entry);
    if (buffer.length > capacity) buffer.splice(0, buffer.length - capacity);
  }
  function recordCoalesced(entry) {
    let last = buffer[buffer.length - 1];
    if (!last || last.type !== entry.type || last.target !== entry.target || last.isTrusted !== entry.isTrusted) {
      record(entry);
      return;
    }
    last.count += 1;
    last.detail = entry.detail;
  }
  var armedListener = (event) => recordCoalesced(toLogged(event));
  function setArmed(on) {
    if (on === armed) return;
    armed = on;
    for (let type of armedTypes) {
      if (on)
        window.addEventListener(type, armedListener, {
          capture: true,
          passive: true
        });
      else window.removeEventListener(type, armedListener, { capture: true });
    }
  }
  function takeEvents(clear, arm, watch2 = null) {
    let events = clear ? buffer : buffer.slice();
    if (clear) buffer = [];
    recording = true;
    installLogger();
    setArmed(false);
    setArmed(arm);
    let watched = watch2 === null ? null : resolveRef(watch2);
    if (!(watched instanceof Element))
      return { ok: true, events, origin: performance.timeOrigin };
    let owners = [
      watched,
      ...Array.from(watched.labels ?? [])
    ];
    let marked = events.map((event) => {
      let target2 = targets.get(event);
      let onTarget = target2 instanceof Node && owners.some(
        (owner) => isWithin(owner, target2) || target2 instanceof Element && isWithin(target2, owner)
      );
      return { ...event, onTarget };
    });
    return { ok: true, events: marked, origin: performance.timeOrigin };
  }
  function detailOf(event) {
    if (event instanceof MouseEvent) {
      let pointer = event instanceof PointerEvent ? ` ${event.pointerType}` : "";
      return `button=${event.button} buttons=${event.buttons} client=${event.clientX},${event.clientY} detail=${event.detail}${pointer}`;
    }
    if (event instanceof KeyboardEvent)
      return `key=${event.key} code=${event.code}`;
    if (event instanceof InputEvent)
      return `inputType=${event.inputType}${event.data === null ? "" : ` data=${JSON.stringify(event.data)}`}`;
    return "";
  }
  var targetOf = (event) => event.composedPath()[0] ?? event.target;
  function toLogged(event) {
    let target2 = targetOf(event);
    return {
      type: event.type,
      isTrusted: event.isTrusted,
      ref: target2 instanceof Element ? existingRef(target2) : null,
      target: describe(target2),
      time: Math.round((performance.timeOrigin + event.timeStamp) * 10) / 10,
      detail: detailOf(event),
      count: 1
    };
  }
  function logListener(event) {
    if (!recording) return;
    let entry = toLogged(event);
    let target2 = targetOf(event);
    if (target2) targets.set(entry, target2);
    record(entry);
  }
  function installLogger() {
    for (let type of loggedTypes) {
      window.addEventListener(type, logListener, {
        capture: true,
        passive: true
      });
    }
  }

  // src/content/mouse.ts
  var presses = {
    left_click: 1,
    double_click: 2,
    triple_click: 3,
    right_click: 1
  };
  var unfocusedInputs = /* @__PURE__ */ new Set([
    "button",
    "checkbox",
    "color",
    "file",
    "hidden",
    "image",
    "radio",
    "range",
    "reset",
    "submit"
  ]);
  function pressFocusable(element) {
    if (element.disabled === true) return false;
    if (element instanceof HTMLInputElement)
      return !unfocusedInputs.has(element.type);
    if (element instanceof HTMLButtonElement) return false;
    if (element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement)
      return true;
    return isEditableRoot(element) || element.hasAttribute("tabindex");
  }
  function focusFor(target2) {
    for (let element = target2; element; element = flatParent(element)) {
      if (!pressFocusable(element)) continue;
      element.focus({ preventScroll: true });
      return;
    }
    document.activeElement?.blur?.();
  }
  function syntheticClick(ref2, action, modifiers) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    let rect = element.getBoundingClientRect();
    let point = {
      left: rect.left + rect.width / 2,
      top: rect.top + rect.height / 2
    };
    let aim = () => {
      let hit = deepElementFromPoint(point);
      return hit && (!element.isConnected || isWithin(element, hit)) ? hit : element;
    };
    let target2 = aim();
    let button = action === "right_click" ? 2 : 0;
    let held = action === "right_click" ? 2 : 1;
    let base = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      clientX: point.left,
      clientY: point.top,
      screenX: window.screenX + point.left,
      screenY: window.screenY + window.outerHeight - window.innerHeight + point.top,
      button,
      ctrlKey: modifiers.includes("ctrl"),
      shiftKey: modifiers.includes("shift"),
      altKey: modifiers.includes("alt"),
      metaKey: modifiers.includes("cmd")
    };
    let dispatched = [];
    let make = (type, buttons, detail) => {
      let init = { ...base, buttons, detail, bubbles: !type.endsWith("enter") };
      if (!type.startsWith("pointer")) return new MouseEvent(type, init);
      return new PointerEvent(type, {
        ...init,
        pointerId: 1,
        pointerType: "mouse",
        isPrimary: true,
        width: 1,
        height: 1,
        pressure: buttons ? 0.5 : 0
      });
    };
    let fire2 = (type, buttons, detail) => {
      let canceled = !target2.dispatchEvent(make(type, buttons, detail));
      dispatched.push({ type, canceled });
      return canceled;
    };
    let enter = (type) => {
      let chain = [];
      for (let at2 = target2; at2; at2 = flatParent(at2))
        chain.unshift(at2);
      for (let at2 of chain) at2.dispatchEvent(make(type, 0, 0));
      dispatched.push({ type, canceled: false });
    };
    fire2("pointerover", 0, 0);
    enter("pointerenter");
    fire2("mouseover", 0, 0);
    enter("mouseenter");
    fire2("pointermove", 0, 0);
    fire2("mousemove", 0, 0);
    target2 = aim();
    for (let count = 1; count <= presses[action]; count++) {
      let silenced = fire2("pointerdown", held, 0);
      let prevented = !silenced && fire2("mousedown", held, count);
      if (!prevented) focusFor(target2);
      if (button === 2) fire2("contextmenu", held, count);
      fire2("pointerup", 0, 0);
      if (!silenced) fire2("mouseup", 0, count);
      fire2(button === 2 ? "auxclick" : "click", 0, count);
      if (count === 2) fire2("dblclick", 0, 2);
    }
    return {
      ok: true,
      ref: ref2,
      target: describe(target2),
      dispatched,
      focused: describe(document.activeElement)
    };
  }

  // src/content/drag.ts
  var steps = 10;
  var centerOf = (element) => {
    let rect = element.getBoundingClientRect();
    return { left: rect.left + rect.width / 2, top: rect.top + rect.height / 2 };
  };
  var nextFrame = () => new Promise((resolve) => {
    if (document.visibilityState === "hidden") {
      let channel = new MessageChannel();
      channel.port1.onmessage = resolve;
      channel.port2.postMessage(null);
      return;
    }
    requestAnimationFrame(resolve);
    setTimeout(resolve, 20);
  });
  function ancestors(element) {
    let chain = [];
    for (let node = element; node; node = flatParent(node))
      chain.push(node);
    return chain;
  }
  function dragSource(hit) {
    for (let node = hit; node; node = flatParent(node))
      if (node.draggable === true) return node;
    return null;
  }
  async function drag(ref2, to) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    let goal = resolveRef(to);
    if (!(goal instanceof Element)) return goal;
    goal.scrollIntoView({
      block: "nearest",
      inline: "nearest",
      behavior: "instant"
    });
    await nextFrame();
    let start = centerOf(element);
    let end = centerOf(goal);
    let first = deepElementFromPoint(start);
    let last = deepElementFromPoint(end);
    if (!first || !isWithin(element, first) || !last || !isWithin(goal, last))
      return {
        ok: false,
        error: `ref ${ref2} ${describe(element)} and ref ${to} ${describe(goal)} are not both hittable on screen at once (one is covered or they do not fit in the viewport together), so nothing was sent`,
        code: "not_actionable"
      };
    let dispatched = [];
    let record2 = (type, canceled) => {
      let previous = dispatched.at(-1);
      if (previous?.type === type) {
        previous.count++;
        previous.canceled ||= canceled;
      } else dispatched.push({ type, canceled, count: 1 });
      return canceled;
    };
    let mouseInit = (point, buttons, bubbles = true) => ({
      bubbles,
      cancelable: bubbles,
      composed: true,
      view: window,
      clientX: point.left,
      clientY: point.top,
      screenX: window.screenX + point.left,
      screenY: window.screenY + window.outerHeight - window.innerHeight + point.top,
      button: 0,
      buttons
    });
    let fire2 = (target2, type, point, buttons, bubbles = true) => {
      let init = mouseInit(point, buttons, bubbles);
      let event = type.startsWith("pointer") ? new PointerEvent(type, {
        ...init,
        pointerId: 1,
        pointerType: "mouse",
        isPrimary: true,
        width: 1,
        height: 1,
        pressure: buttons ? 0.5 : 0
      }) : new MouseEvent(type, { ...init, detail: type === "click" ? 1 : 0 });
      return record2(type, !target2.dispatchEvent(event));
    };
    let transfer = new DataTransfer();
    let fireDrag = (target2, type, point) => record2(
      type,
      !target2.dispatchEvent(
        new DragEvent(type, {
          ...mouseInit(point, type === "dragend" ? 0 : 1),
          cancelable: type !== "dragleave" && type !== "dragend",
          dataTransfer: transfer
        })
      )
    );
    let silenced = fire2(first, "pointerdown", start, 1);
    let prevented = !silenced && fire2(first, "mousedown", start, 1);
    if (!prevented) focusFor(first);
    let source = prevented ? null : dragSource(first);
    let pointed = first;
    let dropTarget = null;
    let accepted = false;
    let moveTo = (hit, point) => {
      if (hit !== pointed) {
        let left = ancestors(pointed);
        let entered = ancestors(hit);
        fire2(pointed, "pointerout", point, 1);
        if (!silenced) fire2(pointed, "mouseout", point, 1);
        for (let node of left.filter((node2) => !entered.includes(node2))) {
          fire2(node, "pointerleave", point, 1, false);
          if (!silenced) fire2(node, "mouseleave", point, 1, false);
        }
        fire2(hit, "pointerover", point, 1);
        if (!silenced) fire2(hit, "mouseover", point, 1);
        for (let node of entered.filter((node2) => !left.includes(node2)).reverse()) {
          fire2(node, "pointerenter", point, 1, false);
          if (!silenced) fire2(node, "mouseenter", point, 1, false);
        }
        pointed = hit;
      }
      fire2(hit, "pointermove", point, 1);
      if (!silenced) fire2(hit, "mousemove", point, 1);
    };
    if (source instanceof HTMLAnchorElement && source.href) {
      transfer.setData("text/uri-list", source.href);
      transfer.setData("text/plain", source.href);
    } else if (source instanceof HTMLImageElement && source.src)
      transfer.setData("text/uri-list", source.src);
    for (let step = 1; step <= steps; step++) {
      await nextFrame();
      let point = {
        left: start.left + (end.left - start.left) * step / steps,
        top: start.top + (end.top - start.top) * step / steps
      };
      let hit = deepElementFromPoint(point) ?? document.documentElement;
      if (step === 1 && source) {
        moveTo(first, start);
        if (fireDrag(source, "dragstart", start)) source = null;
        else fire2(pointed, "pointercancel", start, 0);
      }
      if (!source) {
        moveTo(hit, point);
        continue;
      }
      fireDrag(source, "drag", point);
      if (hit !== dropTarget) {
        fireDrag(hit, "dragenter", point);
        if (dropTarget) fireDrag(dropTarget, "dragleave", point);
        dropTarget = hit;
      }
      accepted = fireDrag(hit, "dragover", point);
    }
    let landed = source ? dropTarget : pointed;
    let dropped = false;
    if (source && accepted) {
      fireDrag(landed, "drop", end);
      dropped = true;
    } else if (source) fireDrag(landed, "dragleave", end);
    if (source) fireDrag(source, "dragend", end);
    else {
      fire2(landed, "pointerup", end, 0);
      if (!silenced) fire2(landed, "mouseup", end, 0);
      let common = ancestors(first).find((node) => isWithin(node, landed));
      if (common) fire2(common, "click", end, 0);
    }
    return {
      ok: true,
      ref: ref2,
      to,
      source: describe(source ?? first),
      target: describe(landed),
      html5: source !== null,
      dropped,
      dispatched
    };
  }

  // src/content/waitFor.ts
  function shownText2(root) {
    let text2 = "";
    let spans = [];
    let add2 = (piece) => {
      let clean = piece.replace(/\s+/g, " ");
      if (clean.startsWith(" ") && (!text2 || text2.endsWith(" ")))
        clean = clean.slice(1);
      text2 += clean;
    };
    let walk = (node, invisible) => {
      for (let child of flatChildren(node)) {
        if (child.nodeType === Node.TEXT_NODE) {
          if (!invisible) add2(child.textContent ?? "");
          continue;
        }
        if (!(child instanceof Element)) continue;
        if (child.localName === "br") {
          add2(" ");
          continue;
        }
        if (isPruned(child) || isField(child)) continue;
        let hidden2 = isInvisible(child);
        let gap2 = isBlock(child) ? " " : "";
        add2(gap2);
        let start = text2.length;
        walk(child, hidden2);
        if (!hidden2) spans.push({ element: child, start, end: text2.length });
        add2(gap2);
      }
    };
    if (!isField(root)) walk(root, root instanceof Element && isInvisible(root));
    return { text: text2, spans };
  }
  var escape = (text2) => text2.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  function elementsShowing(text2, limit = Infinity) {
    let { text: shown2, spans } = shownText2(document);
    let needle = text2.replace(/\s+/g, " ").trim();
    let found = [];
    if (!needle) return found;
    for (let match of shown2.matchAll(new RegExp(escape(needle), "gi"))) {
      let end = match.index + needle.length;
      let span = spans.find(
        (each) => each.start <= match.index && end <= each.end && hasBox(each.element)
      );
      if (!span || found.some((each) => each.element === span.element)) continue;
      found.push({
        element: span.element,
        text: shown2.slice(span.start, span.end)
      });
      if (found.length >= limit) break;
    }
    return found;
  }
  function bySelector(selector) {
    for (let element of flatElements(document)) {
      if (!element.matches(selector) || !hasBox(element)) continue;
      return { element, text: shownText2(element).text };
    }
    return null;
  }
  function waitFor(text2, selector) {
    if (text2 === null === (selector === null))
      return {
        ok: false,
        error: "waitFor takes either text or selector",
        code: "invalid_argument"
      };
    if (selector !== null) {
      try {
        document.querySelector(selector);
      } catch {
        return {
          ok: false,
          error: `${JSON.stringify(selector)} is not a valid CSS selector`,
          code: "invalid_argument"
        };
      }
    }
    let found = text2 === null ? bySelector(selector) : elementsShowing(text2, 1)[0] ?? null;
    let match = found && {
      ...elementInfo(found.element, visibleArea(readViewport())),
      text: collapse(found.text)
    };
    return { ok: true, url: location.href, title: document.title, match };
  }

  // src/content/find.ts
  var findLimit = 20;
  var onScreenFirst = (matches) => [
    ...matches.filter((match) => match.inViewport),
    ...matches.filter((match) => !match.inViewport)
  ];
  var exactFirst = (matches) => [
    ...onScreenFirst(matches.filter((match) => match.exact)),
    ...onScreenFirst(matches.filter((match) => !match.exact))
  ];
  var query = (name, role) => ({
    needle: name.trim().toLowerCase(),
    wantedRole: role.trim().toLowerCase()
  });
  var noQuery = (op) => ({
    ok: false,
    error: `${op} needs a name or a role`,
    code: "invalid_argument"
  });
  function* matching(needle, wantedRole) {
    let named = false;
    for (let element of flatElements(document)) {
      if (!hasBox(element)) continue;
      let elementRole = roleOf(element);
      if (wantedRole && elementRole.toLowerCase() !== wantedRole) continue;
      let interactive = isInteractive(element);
      let inner = interactive || contentRoles.has(elementRole) ? [...flatElements(element)].filter(isInteractive) : [];
      let wraps = !contentRoles.has(elementRole) && inner.length > 0;
      let name = nameOf(
        element,
        (contentRoles.has(elementRole) || interactive && !authorRoles.has(elementRole)) && !wraps
      );
      let only = inner.length === 1 ? inner[0] : null;
      if (only && nameOf(only) === name && (!wantedRole || roleOf(only).toLowerCase() === wantedRole))
        continue;
      if (needle && !name.toLowerCase().includes(needle)) continue;
      named = true;
      yield { element, name };
    }
    if (named || !needle || wantedRole) return;
    for (let { element, text: text2 } of elementsShowing(needle))
      yield { element, name: collapse(text2) };
  }
  function find(name, role) {
    let { needle, wantedRole } = query(name, role);
    if (!needle && !wantedRole) return noQuery("find");
    let visible = visibleArea(readViewport());
    let matches = [];
    let onScreen = 0;
    for (let match of matching(needle, wantedRole)) {
      let info = elementInfo(match.element, visible, match.name);
      matches.push(info);
      if (info.inViewport) onScreen++;
      if (onScreen >= findLimit) break;
    }
    return { ok: true, matches: onScreenFirst(matches).slice(0, findLimit) };
  }
  function target(name, role) {
    let { needle, wantedRole } = query(name, role);
    if (!needle && !wantedRole) return noQuery("target");
    let visible = visibleArea(readViewport());
    let matches = [...matching(needle, wantedRole)].map((match) => ({
      ...elementInfo(match.element, visible, match.name),
      exact: needle !== "" && match.name.trim().toLowerCase() === needle
    }));
    return {
      ok: true,
      matches: exactFirst(matches).slice(0, findLimit),
      matched: matches.length,
      exact: matches.filter((match) => match.exact).length
    };
  }

  // src/content/focus.ts
  function focusRef(ref2) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    let active2 = () => {
      let found = document.activeElement;
      while (found?.shadowRoot?.activeElement)
        found = found.shadowRoot.activeElement;
      return found;
    };
    for (let candidate = element; candidate && candidate !== document.body; candidate = flatParent(candidate)) {
      if (!(candidate instanceof HTMLElement || candidate instanceof SVGElement))
        continue;
      candidate.focus({ preventScroll: true });
      if (active2() === candidate)
        return { ok: true, ref: ref2, focused: describe(candidate), taken: true };
    }
    return { ok: true, ref: ref2, focused: describe(active2()), taken: false };
  }

  // src/content/glow.ts
  var host = null;
  var style = `
div { position: fixed; inset: 0; pointer-events: none; box-shadow: inset 0 0 0 2px rgb(234 88 62 / 0.8), inset 0 0 28px 6px rgb(234 88 62 / 0.45); animation: pulse 2.4s ease-in-out infinite alternate; }
@keyframes pulse { from { opacity: 0.55; } to { opacity: 1; } }
@media (prefers-reduced-motion: reduce) { div { animation: none; } }
`;
  function attach() {
    host = document.createElement("safaripilot-glow");
    host.setAttribute("aria-hidden", "true");
    host.setAttribute(
      "style",
      "all: initial !important; display: block !important; position: fixed !important; inset: 0 !important; z-index: 2147483647 !important; pointer-events: none !important;"
    );
    let root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>${style}</style><div></div>`;
    document.documentElement.append(host);
  }
  function glow(shown2) {
    if (window !== window.top || !document.documentElement) return { ok: true };
    if (!host?.isConnected) attach();
    host.style.setProperty("display", shown2 ? "block" : "none", "important");
    host.getBoundingClientRect();
    return { ok: true };
  }
  async function askPiloted() {
    if (window !== window.top) return;
    let query2 = { op: "piloted" };
    let piloted = await browser.runtime.sendMessage(query2).catch(() => false);
    if (piloted !== true) return;
    if (document.documentElement) {
      glow(true);
      return;
    }
    document.addEventListener("DOMContentLoaded", () => glow(true), {
      once: true
    });
  }

  // src/content/inspect.ts
  var nonTextInputs = /* @__PURE__ */ new Set([
    "checkbox",
    "radio",
    "button",
    "submit",
    "reset",
    "image",
    "file",
    "hidden"
  ]);
  var dateTimeInputs = /* @__PURE__ */ new Set(["date", "time", "datetime-local"]);
  var ariaChecks = {
    checkbox: "checkbox",
    switch: "checkbox",
    radio: "radio"
  };
  function inspect(ref2) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    let base = {
      ok: true,
      ref: ref2,
      hover: element.matches(":hover"),
      value: null,
      secure: false,
      kind: "other",
      checked: null,
      selectedIndex: null,
      options: null,
      min: null,
      max: null
    };
    if (element instanceof HTMLSelectElement) {
      let options = [...element.options].map((option) => ({
        value: option.value,
        label: option.label ?? option.text,
        disabled: option.disabled
      }));
      let listbox = element.multiple || element.size > 1;
      return {
        ...base,
        value: element.value,
        kind: listbox ? "listbox" : "select",
        selectedIndex: element.selectedIndex,
        options
      };
    }
    if (element instanceof HTMLInputElement && (element.type === "checkbox" || element.type === "radio"))
      return {
        ...base,
        value: element.value,
        kind: element.type,
        checked: element.checked
      };
    if (element instanceof HTMLInputElement && element.type === "range")
      return {
        ...base,
        value: element.value,
        kind: "slider",
        min: Number(element.min || 0),
        max: Number(element.max || 100)
      };
    if (element.getAttribute("role") === "slider")
      return {
        ...base,
        value: element.getAttribute("aria-valuenow"),
        kind: "slider",
        min: numberOrNull(element.getAttribute("aria-valuemin")),
        max: numberOrNull(element.getAttribute("aria-valuemax"))
      };
    if (element instanceof HTMLInputElement && element.type === "color")
      return { ...base, value: element.value, kind: "color" };
    if (element instanceof HTMLInputElement && dateTimeInputs.has(element.type))
      return {
        ...base,
        value: element.value,
        kind: element.type
      };
    if (isSensitive(element)) {
      let value = element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement ? element.value : element.innerText;
      return {
        ...base,
        value: "\u2022".repeat(value.length),
        secure: true,
        kind: "text"
      };
    }
    if (element instanceof HTMLInputElement) {
      let kind = nonTextInputs.has(element.type) ? "other" : "text";
      return { ...base, value: element.value, kind };
    }
    if (element instanceof HTMLTextAreaElement)
      return { ...base, value: element.value, kind: "text" };
    if (element instanceof HTMLElement && element.isContentEditable) {
      let placeholder = element.textContent === "" && element.querySelectorAll("br").length < 2;
      return {
        ...base,
        value: placeholder ? "" : element.innerText,
        kind: "text"
      };
    }
    let ariaKind = ariaChecks[element.getAttribute("role") ?? ""];
    if (ariaKind)
      return {
        ...base,
        kind: ariaKind,
        checked: element.getAttribute("aria-checked") === "true"
      };
    return base;
  }
  function numberOrNull(text2) {
    if (text2 === null || text2.trim() === "") return null;
    let number = Number(text2);
    return Number.isFinite(number) ? number : null;
  }
  function fire(element, ...types2) {
    for (let type of types2)
      element.dispatchEvent(new Event(type, { bubbles: true }));
  }
  var settableInputs = /* @__PURE__ */ new Set(["color", "range", ...dateTimeInputs]);
  function setValue(ref2, value) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    if (!(element instanceof HTMLInputElement) || !settableInputs.has(element.type))
      return {
        ok: false,
        error: `ref ${ref2} is not a color, range, date, time or datetime-local input`,
        code: "invalid_argument"
      };
    if (element.disabled || element.readOnly)
      return {
        ok: false,
        error: `${element.type} input ref ${ref2} is ${element.disabled ? "disabled" : "read-only"}`,
        code: "not_actionable"
      };
    if (element.type === "color" && !CSS.supports("color", value))
      return {
        ok: false,
        error: `"${value}" is not a CSS color`,
        code: "invalid_argument"
      };
    element.value = value;
    fire(element, "input", "change");
    return inspect(ref2);
  }
  function announceInput(ref2) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    fire(element, "input", "change");
    return inspect(ref2);
  }
  function selectOption(ref2, index) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    if (!(element instanceof HTMLSelectElement) || !element.options[index])
      return {
        ok: false,
        error: `ref ${ref2} is not a select with an option ${index}`,
        code: "invalid_argument"
      };
    element.selectedIndex = index;
    fire(element, "input", "change");
    return inspect(ref2);
  }

  // src/content/keys.ts
  var modifierKeys = {
    shift: "Shift",
    alt: "Alt",
    ctrl: "Control",
    cmd: "Meta"
  };
  var textInputs = /* @__PURE__ */ new Set([
    "text",
    "search",
    "url",
    "tel",
    "email",
    "password",
    "number"
  ]);
  function active() {
    let found = document.activeElement;
    while (found?.shadowRoot?.activeElement)
      found = found.shadowRoot.activeElement;
    return found ?? document.body;
  }
  var isTextInput = (element) => element instanceof HTMLInputElement && textInputs.has(element.type);
  function isEditable(element) {
    if (isTextInput(element) || element instanceof HTMLTextAreaElement)
      return !element.disabled && !element.readOnly;
    return element.isContentEditable;
  }
  function tabbables() {
    let all = [
      ...document.querySelectorAll(
        "a[href], button, input, select, textarea, summary, iframe, [tabindex], [contenteditable]"
      )
    ].filter(
      (element) => element.tabIndex >= 0 && !element.disabled && element.type !== "hidden" && element.getClientRects().length > 0
    );
    let positive = all.filter((element) => element.tabIndex > 0).sort((one, two) => one.tabIndex - two.tabIndex);
    return [...positive, ...all.filter((element) => element.tabIndex === 0)];
  }
  function moveFocus(from, back) {
    let order = tabbables();
    if (order.length === 0) return null;
    let index = order.indexOf(from);
    let next = index < 0 ? order[back ? order.length - 1 : 0] : order[(index + (back ? -1 : 1) + order.length) % order.length];
    next.focus({ preventScroll: false });
    return `focused ${describe(next)}`;
  }
  function stepRange(input, key) {
    let min = Number(input.min || 0);
    let max = Number(input.max || 100);
    let step = Number(input.step) || 1;
    let moves = {
      ArrowRight: step,
      ArrowUp: step,
      ArrowLeft: -step,
      ArrowDown: -step,
      PageUp: Math.max(step, (max - min) / 10),
      PageDown: -Math.max(step, (max - min) / 10),
      Home: -Infinity,
      End: Infinity
    };
    if (moves[key] === void 0) return null;
    let before = input.value;
    let next = Math.min(max, Math.max(min, Number(before) + moves[key]));
    input.value = String(min + Math.round((next - min) / step) * step);
    if (input.value === before) return null;
    fire(input, "input", "change");
    return `set the range to ${input.value}`;
  }
  function stepSelect(select, down) {
    let index = select.selectedIndex;
    do
      index += down ? 1 : -1;
    while (select.options[index]?.disabled);
    if (!select.options[index]) return null;
    select.selectedIndex = index;
    fire(select, "input", "change");
    return `selected "${select.options[index].label}"`;
  }
  function moveCaret(element, key, extend2) {
    if (element instanceof HTMLInputElement && element.type === "number") {
      if (key !== "ArrowUp" && key !== "ArrowDown") return null;
      let before = element.value;
      if (key === "ArrowUp") element.stepUp();
      else element.stepDown();
      if (element.value === before) return null;
      fire(element, "input", "change");
      return `set the number to ${element.value}`;
    }
    let done = extend2 ? "extended the selection" : "moved the caret";
    if (isTextInput(element) || element instanceof HTMLTextAreaElement) {
      let field = element;
      let start = field.selectionStart ?? 0;
      let end = field.selectionEnd ?? 0;
      let length = field.value.length;
      let single = !(element instanceof HTMLTextAreaElement);
      let target2 = key === "ArrowLeft" ? Math.max(0, (start === end || extend2 ? start : start + 1) - 1) : key === "ArrowRight" ? Math.min(length, (start === end || extend2 ? end : end - 1) + 1) : key === "Home" || single && key === "ArrowUp" ? 0 : key === "End" || single && key === "ArrowDown" ? length : null;
      if (target2 === null) {
        getSelection()?.modify(
          extend2 ? "extend" : "move",
          key === "ArrowUp" ? "backward" : "forward",
          "line"
        );
        return done;
      }
      if (extend2)
        field.setSelectionRange(
          Math.min(start, target2),
          Math.max(end, target2),
          target2 < start ? "backward" : "forward"
        );
      else field.setSelectionRange(target2, target2);
      return done;
    }
    let units = {
      ArrowLeft: ["backward", "character"],
      ArrowRight: ["forward", "character"],
      ArrowUp: ["backward", "line"],
      ArrowDown: ["forward", "line"],
      Home: ["backward", "lineboundary"],
      End: ["forward", "lineboundary"]
    };
    let unit = units[key];
    if (!unit) return null;
    getSelection()?.modify(extend2 ? "extend" : "move", unit[0], unit[1]);
    return done;
  }
  function scrollPage(key, shift) {
    let page2 = document.scrollingElement ?? document.documentElement;
    let height = innerHeight * 0.875;
    let deltas = {
      ArrowDown: 40,
      ArrowUp: -40,
      PageDown: height,
      PageUp: -height,
      Space: shift ? -height : height,
      Home: -page2.scrollHeight,
      End: page2.scrollHeight
    };
    if (deltas[key] === void 0) return null;
    let before = page2.scrollTop;
    page2.scrollBy({ top: deltas[key], behavior: "instant" });
    return page2.scrollTop === before ? null : `scrolled to ${page2.scrollTop}`;
  }
  function defaultAction(element, press) {
    let held = (modifier) => press.modifiers.includes(modifier);
    let editable = isEditable(element);
    if (press.character && !held("ctrl") && !held("cmd")) {
      if (editable) {
        document.execCommand("insertText", false, press.character);
        return "inserted text";
      }
      if (press.key !== " ") return null;
    }
    if (press.key === "Tab") return moveFocus(element, held("shift"));
    if (press.key === "Enter") {
      if (element instanceof HTMLTextAreaElement && editable) {
        document.execCommand("insertText", false, "\n");
        return "inserted a line break";
      }
      if (editable && element.isContentEditable) {
        document.execCommand(
          held("shift") ? "insertLineBreak" : "insertParagraph"
        );
        return "inserted a paragraph";
      }
      if (element instanceof HTMLInputElement && element.form) {
        element.form.requestSubmit();
        return "submitted its form";
      }
      if (element.matches("a[href], button, summary, [role=button]")) {
        element.click();
        return "clicked it";
      }
      return null;
    }
    if (press.key === " " || press.key === "Space") {
      if (element.matches(
        "button, summary, input[type=checkbox], input[type=radio], input[type=button], input[type=submit], input[type=reset], [role=button], [role=checkbox]"
      )) {
        element.click();
        return "clicked it";
      }
      return scrollPage("Space", held("shift"));
    }
    if (press.key === "Backspace" || press.key === "Delete") {
      if (!editable) return null;
      document.execCommand(
        press.key === "Backspace" ? "delete" : "forwardDelete"
      );
      return "deleted";
    }
    if (element instanceof HTMLInputElement && element.type === "range")
      return stepRange(element, press.key);
    if (element instanceof HTMLSelectElement && (press.key === "ArrowDown" || press.key === "ArrowUp"))
      return stepSelect(element, press.key === "ArrowDown");
    if (editable) return moveCaret(element, press.key, held("shift"));
    return scrollPage(press.key, held("shift"));
  }
  var keyCodes = {
    Backspace: 8,
    Tab: 9,
    Enter: 13,
    Shift: 16,
    Control: 17,
    Alt: 18,
    Escape: 27,
    " ": 32,
    PageUp: 33,
    PageDown: 34,
    End: 35,
    Home: 36,
    ArrowLeft: 37,
    ArrowUp: 38,
    ArrowRight: 39,
    ArrowDown: 40,
    Delete: 46,
    Meta: 91
  };
  function codeOf(key) {
    if (/^[a-z]$/i.test(key)) return `Key${key.toUpperCase()}`;
    if (/^[0-9]$/.test(key)) return `Digit${key}`;
    if (key === " ") return "Space";
    if (Object.values(modifierKeys).includes(key)) return `${key}Left`;
    return key.length > 1 ? key : "";
  }
  function keyboardEvent(type, key, modifiers) {
    let printable = key.length === 1;
    let keyCode = type === "keypress" ? printable ? key.charCodeAt(0) : keyCodes[key] ?? 0 : keyCodes[key] ?? (/^[a-z0-9]$/i.test(key) ? key.toUpperCase().charCodeAt(0) : 0);
    return new KeyboardEvent(type, {
      key,
      code: codeOf(key),
      keyCode,
      which: keyCode,
      charCode: type === "keypress" && printable ? keyCode : 0,
      bubbles: true,
      cancelable: true,
      composed: true,
      shiftKey: modifiers.includes("shift"),
      altKey: modifiers.includes("alt"),
      ctrlKey: modifiers.includes("ctrl"),
      metaKey: modifiers.includes("cmd")
    });
  }
  function syntheticKeys(ref2, presses2) {
    if (ref2 !== null) {
      let focused = focusRef(ref2);
      if (!focused.ok) return focused;
    }
    let start = active();
    let results = [];
    for (let press of presses2) {
      let element = active();
      if (isFrameHost(element))
        return {
          ok: false,
          error: `focus is inside iframe ${describe(element)}; pass a ref inside its frame, such as ${refFor(element)}:N`,
          code: "not_actionable"
        };
      let key = press.key === "Space" ? " " : press.character ?? press.key;
      let held = [];
      for (let modifier of press.modifiers) {
        held.push(modifier);
        element.dispatchEvent(
          keyboardEvent("keydown", modifierKeys[modifier], held)
        );
      }
      let canceled = !element.dispatchEvent(
        keyboardEvent("keydown", key, press.modifiers)
      );
      if (!canceled && (press.character || press.key === "Enter"))
        canceled = !element.dispatchEvent(
          keyboardEvent("keypress", key, press.modifiers)
        );
      let action = canceled ? null : defaultAction(element, {
        ...press,
        key: press.key === "Space" ? " " : press.key
      });
      element.dispatchEvent(keyboardEvent("keyup", key, press.modifiers));
      for (let modifier of [...press.modifiers].reverse()) {
        held.pop();
        element.dispatchEvent(
          keyboardEvent("keyup", modifierKeys[modifier], held)
        );
      }
      results.push({ key: press.key, canceled, action });
    }
    return {
      ok: true,
      target: describe(start),
      presses: results,
      focused: describe(active())
    };
  }

  // src/content/locate.ts
  var sameRect = (first, second) => first.left === second.left && first.top === second.top && first.width === second.width && first.height === second.height;
  async function settledRect(element) {
    let previous = toRect(boxOf(element));
    for (let frame = 0; frame < 30; frame++) {
      await new Promise((resolve) => {
        requestAnimationFrame(resolve);
        setTimeout(resolve, 100);
      });
      let current2 = toRect(boxOf(element));
      if (sameRect(previous, current2)) return current2;
      previous = current2;
    }
    return previous;
  }
  async function locate(ref2, clip2, scroll2) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    if (scroll2)
      element.scrollIntoView({
        block: "center",
        inline: "nearest",
        behavior: "instant"
      });
    let rect = await settledRect(element);
    let viewport = readViewport();
    let center = {
      left: rect.left + rect.width / 2,
      top: rect.top + rect.height / 2
    };
    let labels = element instanceof HTMLInputElement && (element.type === "checkbox" || element.type === "radio") ? Array.from(element.labels ?? []) : [];
    let base = {
      ok: true,
      ref: ref2,
      rect: labels.reduce(
        (union, label) => unite(union, toRect(label.getBoundingClientRect())),
        rect
      ),
      link: element.closest("a[href], area[href]") !== null,
      viewport,
      candidates: []
    };
    if (rect.width <= 0 || rect.height <= 0)
      return {
        ...base,
        point: center,
        hitsTarget: false,
        covered: false,
        hitDescription: "element has no box"
      };
    let area = clip2 ? intersect(visibleArea(viewport), clip2) : visibleArea(viewport);
    let shown2 = area && intersect(rect, area);
    if (!shown2)
      return {
        ...base,
        point: center,
        hitsTarget: false,
        covered: false,
        hitDescription: "element is outside the viewport"
      };
    let owners = [
      element,
      ...Array.from(element.labels ?? [])
    ];
    let hits = (candidate) => {
      let hit = deepElementFromPoint(candidate);
      return owners.some((owner) => isWithin(owner, hit));
    };
    let candidates = clip2 ? candidatePoints(rect, shown2).filter(hits).slice(0, 8) : [];
    let point = clip2 ? candidates[0] ?? null : pickPoint(rect, shown2, hits);
    if (point)
      return {
        ...base,
        candidates,
        point,
        hitsTarget: true,
        covered: false,
        hitDescription: describe(deepElementFromPoint(point))
      };
    let fallback = candidatePoints(rect, shown2)[0];
    return {
      ...base,
      point: fallback,
      hitsTarget: false,
      covered: true,
      hitDescription: `covered by ${describe(deepElementFromPoint(fallback))}`
    };
  }

  // src/content/pageFetch.ts
  var waiting3 = /* @__PURE__ */ new Map();
  var onAnswer2 = (event) => {
    let message;
    try {
      message = Object(JSON.parse(String(event.detail)));
    } catch {
      return;
    }
    let deliver = waiting3.get(String(message.id));
    if (!deliver) return;
    event.stopImmediatePropagation();
    deliver(message);
  };
  var installPageFetchReader = () => window.addEventListener(fetchAnswerEvent, onAnswer2, true);
  var randomId = () => Array.from(
    crypto.getRandomValues(new Uint8Array(16)),
    (byte) => byte.toString(16).padStart(2, "0")
  ).join("");
  var answerOf = (raw) => ({
    ok: true,
    status: Number(raw.status) || 0,
    statusText: String(raw.statusText ?? ""),
    url: String(raw.url ?? ""),
    redirected: raw.redirected === true,
    headers: (Array.isArray(raw.headers) ? raw.headers : []).map((header2) => ({
      name: String(header2?.name),
      value: String(header2?.value)
    })),
    contentType: String(raw.contentType ?? ""),
    binary: raw.binary === true,
    size: Number(raw.size) || 0,
    body: typeof raw.body === "string" ? raw.body.slice(0, maxFetchBody) : null,
    truncated: raw.truncated === true
  });
  var codes = ["invalid_argument", "timed_out", "failed"];
  async function pageFetch(request) {
    installPageFetchReader();
    let id = randomId();
    let accepted = false;
    let timer;
    let answered = new Promise((resolve) => {
      waiting3.set(id, (message) => {
        if (message.accepted === true) accepted = true;
        else resolve(message);
      });
      timer = setTimeout(() => resolve(null), request.timeoutMs + 2e3);
    });
    try {
      let { op: _op, ...detail } = request;
      window.dispatchEvent(
        new CustomEvent(fetchEvent, {
          detail: JSON.stringify({ id, ...detail })
        })
      );
      if (!accepted)
        return {
          ok: false,
          error: "no main-world capture answered in this frame: it runs no scripts (sandboxed), or document.open() replaced its document and no fetch has armed the capture since; reload the page",
          code: "not_actionable"
        };
      let message = await answered;
      if (!message)
        return {
          ok: false,
          error: `the page did not answer within ${request.timeoutMs / 1e3 + 2} s`,
          code: "timed_out"
        };
      if (message.failure) {
        let failure = Object(message.failure);
        let code = codes.find((known) => known === failure.code) ?? "failed";
        return { ok: false, error: String(failure.error), code };
      }
      return answerOf(Object(message.answer));
    } finally {
      clearTimeout(timer);
      waiting3.delete(id);
    }
  }

  // src/content/markdown.ts
  var listTags = /* @__PURE__ */ new Set(["ul", "ol", "menu"]);
  var skippedTags2 = /* @__PURE__ */ new Set([
    "iframe",
    "frame",
    "object",
    "embed",
    "video",
    "audio",
    "canvas"
  ]);
  var nested = (sink, inline = sink.inline) => ({
    blocks: [],
    line: "",
    inline,
    inLink: sink.inLink,
    budget: sink.budget
  });
  function append(sink, text2) {
    let clean = text2.replace(/\s+/g, " ");
    if (clean.startsWith(" ") && (!sink.line || /[ \n]$/.test(sink.line)))
      clean = clean.slice(1);
    sink.line += clean;
    sink.budget.left -= clean.length;
  }
  function push(sink, block) {
    if (block) sink.blocks.push(block);
  }
  function flush(sink) {
    let lines = sink.line.split("\n").map((line) => line.trim());
    sink.line = "";
    push(sink, lines.filter(Boolean).join("\n"));
  }
  function inlineText(node, sink, inLink = sink.inLink) {
    let inner = { ...nested(sink, true), inLink };
    flow(node, inner);
    flush(inner);
    return inner.blocks.join(" ").replace(/\s+/g, " ").trim();
  }
  function flow(node, sink, invisible = false) {
    for (let child of flatChildren(node)) {
      if (sink.budget.left <= 0) return;
      if (child.nodeType === Node.TEXT_NODE) {
        if (!invisible) append(sink, child.textContent ?? "");
        continue;
      }
      if (child instanceof Element) write(child, sink);
    }
  }
  function rawText(node, invisible = false) {
    let text2 = "";
    let breakLine = () => {
      if (text2 && !text2.endsWith("\n")) text2 += "\n";
    };
    for (let child of flatChildren(node)) {
      if (child.nodeType === Node.TEXT_NODE) {
        if (!invisible) text2 += child.textContent ?? "";
        continue;
      }
      if (!(child instanceof Element)) continue;
      if (child.localName === "br") {
        text2 += "\n";
        continue;
      }
      if (isPruned(child)) continue;
      let block = isBlock(child);
      if (block) breakLine();
      text2 += rawText(child, isInvisible(child));
      if (block) breakLine();
    }
    return text2;
  }
  function hrefOf(anchor) {
    if (!URL.canParse(anchor.href, location.href)) return null;
    let url = new URL(anchor.href, location.href);
    if (url.protocol === "javascript:") return null;
    let local = url.origin === location.origin && url.protocol.startsWith("http");
    return redactUrl(
      local ? `${url.pathname}${url.search}${url.hash}` : url.href
    );
  }
  function heading(element, sink) {
    let text2 = inlineText(element, sink);
    if (sink.inline) {
      append(sink, ` ${text2} `);
      return;
    }
    let level = Number(
      element.getAttribute("aria-level") ?? element.localName.match(/^h([1-6])$/)?.[1]
    ) || 2;
    flush(sink);
    push(sink, text2 && `${"#".repeat(Math.min(Math.max(level, 1), 6))} ${text2}`);
  }
  function list(element, sink) {
    if (sink.inline) {
      flow(element, sink, isInvisible(element));
      return;
    }
    flush(sink);
    let ordered = element.localName === "ol";
    let number = ordered ? element.start : 1;
    let lines = [];
    for (let child of flatChildren(element)) {
      if (!(child instanceof Element) || isPruned(child)) continue;
      let item = nested(sink);
      let isItem = child.localName === "li" || child.getAttribute("role") === "listitem";
      if (isItem) flow(child, item, isInvisible(child));
      else write(child, item);
      flush(item);
      let content = item.blocks.join("\n");
      if (!content) continue;
      let marker = ordered ? `${number++}. ` : "- ";
      let indent = " ".repeat(marker.length);
      lines.push(
        ...content.split("\n").map(
          (line, index) => index === 0 ? `${marker}${line}` : line && `${indent}${line}`
        )
      );
    }
    push(sink, lines.join("\n"));
  }
  var isDataTable = (table2) => !/^(presentation|none)$/.test(table2.getAttribute("role") ?? "") && !table2.querySelector("table");
  var ariaTableRoles = /* @__PURE__ */ new Set(["table", "grid", "treegrid"]);
  var ariaCellRoles = /* @__PURE__ */ new Set(["cell", "gridcell", "columnheader", "rowheader"]);
  var cellOf = (cell, span, sink) => [
    inlineText(cell, sink).replace(/[\\|]/g, "\\$&"),
    ...Array(Math.max(span - 1, 0)).fill("")
  ];
  function* byRole(root, roles, stop2) {
    for (let child of flatChildren(root)) {
      if (!(child instanceof Element) || isPruned(child)) continue;
      let role = roleOf(child);
      if (roles.has(role)) {
        if (!isInvisible(child)) yield child;
        continue;
      }
      if (!stop2.has(role)) yield* byRole(child, roles, stop2);
    }
  }
  function ariaRows(element, sink) {
    let rows = /* @__PURE__ */ new Map();
    for (let row of byRole(element, /* @__PURE__ */ new Set(["row"]), ariaTableRoles)) {
      let key = row.getAttribute("aria-rowindex") ?? row;
      let cells = [...byRole(row, ariaCellRoles, ariaTableRoles)].map(
        (cell, order) => ({
          index: Number(cell.getAttribute("aria-colindex") ?? order),
          cells: cellOf(
            cell,
            Number(cell.getAttribute("aria-colspan") ?? 1),
            sink
          )
        })
      );
      rows.set(key, [...rows.get(key) ?? [], ...cells]);
    }
    return [...rows.values()].map(
      (cells) => cells.sort((one, other) => one.index - other.index).flatMap((cell) => cell.cells)
    );
  }
  function table(element, sink) {
    if (sink.inline) {
      flow(element, sink);
      return;
    }
    flush(sink);
    let caption = element instanceof HTMLTableElement ? element.caption : null;
    if (caption && isShown(caption)) push(sink, inlineText(caption, sink));
    let rows = (element instanceof HTMLTableElement ? Array.from(element.rows).filter(isShown).map(
      (row) => Array.from(row.cells).filter(isShown).flatMap((cell) => cellOf(cell, cell.colSpan, sink))
    ) : ariaRows(element, sink)).map((cells) => {
      while (cells.length && !cells.at(-1)) cells.pop();
      return cells;
    }).filter((cells) => cells.length);
    if (!rows.length) return;
    let width = Math.max(...rows.map((cells) => cells.length));
    let line = (cells) => `| ${[...cells, ...Array(width - cells.length).fill("")].join(" | ")} |`;
    push(
      sink,
      [
        line(rows[0]),
        line(Array(width).fill("---")),
        ...rows.slice(1).map(line)
      ].join("\n")
    );
    let count = Number(element.getAttribute("aria-rowcount"));
    let rendered = element instanceof HTMLTableElement ? element.rows.length : new Set(
      [...byRole(element, /* @__PURE__ */ new Set(["row"]), ariaTableRoles)].map(
        (row) => row.getAttribute("aria-rowindex") ?? row
      )
    ).size;
    if (count > rendered)
      push(
        sink,
        `(${rendered} of the grid's ${count} rows are rendered; scrolling the grid renders others)`
      );
  }
  function isCodeEditor(element) {
    if (!isEditableRoot(element)) return false;
    let style2 = getComputedStyle(element);
    return style2.whiteSpace.startsWith("pre") && (element.hasAttribute("data-language") || style2.fontFamily.includes("monospace"));
  }
  function pre(element, sink) {
    let text2 = rawText(element).replace(/\n+$/, "");
    if (sink.inline) {
      append(sink, ` ${text2} `);
      return;
    }
    sink.budget.left -= text2.length;
    let classes = `${element.className} ${element.querySelector("code")?.className ?? ""}`;
    let language = element.getAttribute("data-language") ?? classes.match(/\b(?:language|lang)-([\w+#-]+)/)?.[1] ?? "";
    let fence = text2.includes("```") ? "````" : "```";
    flush(sink);
    push(sink, text2 && `${fence}${language}
${text2}
${fence}`);
  }
  function quote(element, sink) {
    if (sink.inline) {
      flow(element, sink);
      return;
    }
    flush(sink);
    let inner = nested(sink);
    flow(element, inner);
    flush(inner);
    if (!inner.blocks.length) return;
    let lines = inner.blocks.join("\n\n").split("\n");
    push(sink, lines.map((line) => line ? `> ${line}` : ">").join("\n"));
  }
  function link(element, sink) {
    if (sink.inLink) {
      flow(element, sink);
      return;
    }
    let text2 = inlineText(element, sink, true) || nameOf(element);
    let href = hrefOf(element);
    if (!text2) return;
    let written = href === null ? text2 : `[${text2}](${href})`;
    if (sink.inline || !isBlock(element)) {
      append(sink, written);
      return;
    }
    flush(sink);
    push(sink, written);
  }
  function write(element, sink) {
    let tag = element.localName;
    if (tag === "br") {
      sink.line += sink.inline ? " " : "\n";
      return;
    }
    if (isPruned(element) || skippedTags2.has(tag)) return;
    if (element instanceof HTMLInputElement && /^(checkbox|radio)$/.test(element.type)) {
      append(sink, element.checked ? " [x] " : " [ ] ");
      return;
    }
    if (isField(element)) return;
    let role = roleOf(element);
    let isList = listTags.has(tag) || role === "list";
    if (isInvisible(element) && !isList) {
      flow(element, sink, true);
      return;
    }
    if (role === "heading") return heading(element, sink);
    if (tag === "pre" || isCodeEditor(element)) return pre(element, sink);
    if (element instanceof HTMLTableElement ? isDataTable(element) : ariaTableRoles.has(role))
      return table(element, sink);
    if (isList) return list(element, sink);
    if (tag === "blockquote") return quote(element, sink);
    if (element instanceof HTMLAnchorElement && element.hasAttribute("href"))
      return link(element, sink);
    if (role === "img") {
      let name = nameOf(element, false);
      if (name && !sink.line.endsWith(`![${name}]`)) append(sink, `![${name}]`);
      return;
    }
    if (tag === "hr") {
      if (sink.inline) return;
      flush(sink);
      push(sink, "---");
      return;
    }
    if (tag === "code") {
      let text2 = rawText(element).replace(/\s+/g, " ").trim();
      let tick = text2.includes("`") ? "``" : "`";
      if (text2) append(sink, `${tick}${text2}${tick}`);
      return;
    }
    if (!isBlock(element)) {
      let apart = setsApart(element);
      if (apart) append(sink, " ");
      flow(element, sink);
      if (apart) append(sink, " ");
      return;
    }
    if (sink.inline) {
      append(sink, " ");
      flow(element, sink);
      append(sink, " ");
      return;
    }
    flush(sink);
    flow(element, sink);
    flush(sink);
  }
  function markdownOf(root, maxChars) {
    let sink = {
      blocks: [],
      line: "",
      inline: false,
      inLink: false,
      budget: { left: maxChars + 1 }
    };
    write(root, sink);
    flush(sink);
    return { text: sink.blocks.join("\n\n"), cut: sink.budget.left <= 0 };
  }

  // src/content/pageText.ts
  var isShown2 = (element) => element.checkVisibility();
  function textRoot() {
    let main = Array.from(document.querySelectorAll("main, [role=main]")).find(
      isShown2
    );
    if (main) return main;
    let articles = Array.from(document.querySelectorAll("article")).filter(
      isShown2
    );
    if (articles.length === 1) return articles[0];
    return document.body ?? document.documentElement;
  }
  function clip(text2, maxChars) {
    if (text2.length <= maxChars) return { text: text2, truncated: false };
    let cut = text2.lastIndexOf("\n", maxChars);
    return { text: text2.slice(0, cut > 0 ? cut : maxChars), truncated: true };
  }
  var isPositioned = (element) => /^(absolute|fixed)$/.test(getComputedStyle(element).position);
  function renderedText(root) {
    let positioned = new Set(
      Array.from(root.querySelectorAll("*")).filter(isPositioned)
    );
    let holders = /* @__PURE__ */ new Set();
    for (let element of positioned)
      for (let at2 = element.parentElement; at2 && at2 !== root.parentElement; at2 = at2.parentElement)
        holders.add(at2);
    let textOf2 = (node) => {
      if (node instanceof Text)
        return getComputedStyle(node.parentElement).visibility === "hidden" ? "" : node.data.replace(/\s+/g, " ");
      if (!(node instanceof HTMLElement)) return "";
      if (node.localName === "br") return "\n";
      if (getComputedStyle(node).display === "none") return "";
      let text2 = holders.has(node) ? Array.from(node.childNodes, textOf2).join("") : node.innerText;
      return positioned.has(node) || isBlock(node) ? `\0${text2}\0` : text2;
    };
    return positioned.size ? textOf2(root).replace(/\0[\s\0]*/g, "\n") : root.innerText ?? "";
  }
  var innerTextOf = (root) => renderedText(root).split("\n").map((line) => line.replace(/\s+/g, " ").trim()).join("\n").replace(/\n{3,}/g, "\n\n").trim();
  function pageText(maxChars, format, ref2) {
    let root = ref2 === null ? textRoot() : resolveRef(ref2);
    if (!(root instanceof Element)) return root;
    let { text: text2, cut } = format === "markdown" ? markdownOf(root, maxChars) : { text: innerTextOf(root), cut: false };
    let clipped = clip(text2, maxChars);
    let frames = ref2 === null || isPruned(root) ? [] : [root, ...flatElements(root)].filter(isFrameHost).map(refFor);
    return {
      ok: true,
      url: location.href,
      title: document.title,
      text: clipped.text,
      truncated: clipped.truncated || cut,
      frames
    };
  }

  // src/content/upload.ts
  var isFileInput = (node) => node instanceof HTMLInputElement && node.type === "file";
  function* fileInputs(root) {
    for (let child of flatChildren(root)) {
      if (isFileInput(child)) yield child;
      yield* fileInputs(child);
    }
  }
  var listed = (inputs) => inputs.map((input) => `[ref=${refFor(input)}] ${describe(input)}`).join(", ");
  var shown = (files) => Array.from(files, (file) => ({
    name: file.name,
    size: file.size,
    type: file.type
  }));
  function setInput(ref2, input, transfer) {
    let count = transfer.files.length;
    if (input.disabled)
      return {
        ok: false,
        error: `${describe(input)} is disabled`,
        code: "not_actionable"
      };
    if (count > 1 && !input.multiple)
      return {
        ok: false,
        error: `${describe(input)} takes one file (it has no multiple attribute) and ${count} were given; nothing was set`,
        code: "invalid_argument"
      };
    input.files = transfer.files;
    let taken = Array.from(input.files ?? [], (file) => file.name);
    let wanted = Array.from(transfer.files, (file) => file.name);
    if (taken.join("/") !== wanted.join("/"))
      return {
        ok: false,
        error: `${describe(input)} holds ${JSON.stringify(taken)} after assigning ${JSON.stringify(wanted)}`,
        code: "input_unconfirmed"
      };
    let dispatched = ["input", "change"].map((type) => ({
      type,
      canceled: !input.dispatchEvent(
        new Event(type, { bubbles: true, composed: type === "input" })
      )
    }));
    return {
      ok: true,
      ref: ref2,
      target: describe(input),
      via: "input",
      files: shown(input.files),
      dispatched
    };
  }
  function drop(ref2, element, transfer) {
    let rect = element.getBoundingClientRect();
    let point = {
      left: rect.left + rect.width / 2,
      top: rect.top + rect.height / 2
    };
    let hit = deepElementFromPoint(point);
    let target2 = hit && isWithin(element, hit) ? hit : element;
    let dispatched = [];
    let fire2 = (type) => {
      let event = new DragEvent(type, {
        bubbles: true,
        cancelable: type !== "dragleave",
        composed: true,
        view: window,
        clientX: point.left,
        clientY: point.top,
        dataTransfer: transfer
      });
      let canceled = !target2.dispatchEvent(event);
      dispatched.push({ type, canceled });
      return canceled;
    };
    fire2("dragenter");
    if (!fire2("dragover")) {
      fire2("dragleave");
      let inputs = [...fileInputs(document)];
      let hint = inputs.length ? `; this frame's file inputs: ${listed(inputs)}` : "; this frame has no file input";
      return {
        ok: false,
        error: `${describe(target2)} did not accept a drop (no dragover listener called preventDefault), so nothing was dropped${hint}`,
        code: "not_actionable"
      };
    }
    fire2("drop");
    return {
      ok: true,
      ref: ref2,
      target: describe(target2),
      via: "drop",
      files: shown(transfer.files),
      dispatched
    };
  }
  function upload(ref2, files) {
    let element = resolveRef(ref2);
    if (!(element instanceof Element)) return element;
    if (isFrameHost(element))
      return {
        ok: false,
        error: `${describe(element)} is an iframe; pass the ref of the file input or drop zone inside its frame, such as ${ref2}:12`,
        code: "invalid_argument"
      };
    let transfer = new DataTransfer();
    for (let file of files)
      transfer.items.add(
        new File([Uint8Array.fromBase64(file.data)], file.name, {
          type: file.mimeType,
          lastModified: file.lastModified
        })
      );
    if (isFileInput(element)) return setInput(ref2, element, transfer);
    let control = element.control;
    if (isFileInput(control)) return setInput(ref2, control, transfer);
    let inside2 = [...fileInputs(element)];
    if (inside2.length === 1) return setInput(ref2, inside2[0], transfer);
    if (inside2.length > 1)
      return {
        ok: false,
        error: `${describe(element)} holds ${inside2.length} file inputs, so pass the ref of one: ${listed(inside2)}`,
        code: "invalid_argument"
      };
    return drop(ref2, element, transfer);
  }

  // src/content/index.ts
  installLogger();
  installReader();
  installNetworkReader();
  installPageFetchReader();
  var reads = /* @__PURE__ */ new Set(["readPage", "pageText", "find", "target", "waitFor"]);
  async function handle(request) {
    try {
      if (reads.has(request.op) && window === window.top && document.contentType === "application/pdf")
        return {
          ok: false,
          error: "this tab shows a PDF in Safari's PDF viewer, whose text page tools cannot read; screenshot shows it",
          code: "not_a_web_page"
        };
      if (request.op === "ping")
        return { ok: true, url: location.href, title: document.title };
      if (request.op === "glow") return glow(request.shown);
      if (request.op === "snapshot") return snapshot();
      if (request.op === "locate")
        return await locate(request.ref, request.clip, request.scroll);
      if (request.op === "events")
        return takeEvents(request.clear, request.arm, request.watch);
      if (request.op === "inspect") return inspect(request.ref);
      if (request.op === "setValue") return setValue(request.ref, request.value);
      if (request.op === "selectOption")
        return selectOption(request.ref, request.index);
      if (request.op === "announceInput") return announceInput(request.ref);
      if (request.op === "keys")
        return syntheticKeys(request.ref, request.presses);
      if (request.op === "focus") return focusRef(request.ref);
      if (request.op === "syntheticClick")
        return syntheticClick(request.ref, request.action, request.modifiers);
      if (request.op === "drag") return await drag(request.ref, request.to);
      if (request.op === "upload") return upload(request.ref, request.files);
      if (request.op === "readPage")
        return readPage(
          request.filter,
          request.maxChars,
          request.ref,
          request.depth,
          request.prefix,
          request.viewport,
          request.clip
        );
      if (request.op === "find") return find(request.name, request.role);
      if (request.op === "target") return target(request.name, request.role);
      if (request.op === "waitFor")
        return waitFor(request.text, request.selector);
      if (request.op === "pageText")
        return pageText(request.maxChars, request.format, request.ref);
      if (request.op === "scroll")
        return scroll(request.ref, request.left, request.top);
      if (request.op === "scrollIntoView") return scrollIntoView(request.ref);
      if (request.op === "frames") return listFrames();
      if (request.op === "frameBox") return frameBox(request.ref, request.reveal);
      if (request.op === "hitFrame") return hitFrame(request.ref, request.points);
      if (request.op === "console")
        return takeConsole(
          request.onlyErrors,
          request.pattern,
          request.limit,
          request.clear
        );
      if (request.op === "networkBody")
        return takeBody(request.url, request.method, request.time);
      if (request.op === "pageFetch") return await pageFetch(request);
      if (request.op === "diffStart") return startDiff();
      if (request.op === "diff")
        return await takeDiff(request.prefix, request.waitMs, request.maxChars);
      return {
        ok: false,
        error: `unknown op ${JSON.stringify(request.op)}`,
        code: "failed"
      };
    } catch (error) {
      return {
        ok: false,
        error: `${request.op} failed: ${error instanceof Error ? error.message : String(error)}`,
        code: "failed"
      };
    }
  }
  var shared = globalThis;
  var copy = (shared.safaripilotCopy ?? 0) + 1;
  shared.safaripilotCopy = copy;
  browser.runtime.onMessage.addListener(
    (request) => copy === shared.safaripilotCopy ? handle(request) : void 0
  );
  void askPiloted();

  // src/background/frames.ts
  var thrown = (failure) => Object.assign(new Error(failure.error), { failure });
  var failureFrom = (error) => error?.failure ?? null;

  // node_modules/acorn/dist/acorn.mjs
  var astralIdentifierCodes = [509, 0, 227, 0, 150, 4, 294, 9, 1368, 2, 2, 1, 6, 3, 41, 2, 5, 0, 166, 1, 574, 3, 9, 9, 7, 9, 32, 4, 318, 1, 31, 4, 33, 15, 71, 10, 50, 3, 123, 2, 54, 14, 32, 10, 3, 1, 11, 3, 46, 10, 8, 0, 46, 9, 7, 2, 37, 13, 2, 9, 6, 1, 45, 0, 13, 2, 49, 13, 9, 3, 2, 11, 83, 11, 7, 0, 3, 0, 158, 11, 6, 9, 7, 3, 56, 1, 2, 6, 3, 1, 3, 2, 10, 0, 11, 1, 3, 6, 4, 4, 68, 8, 2, 0, 3, 0, 2, 3, 2, 4, 2, 0, 15, 1, 83, 17, 10, 9, 5, 0, 82, 19, 13, 9, 214, 6, 3, 8, 28, 1, 83, 16, 16, 9, 82, 12, 9, 9, 7, 19, 58, 14, 5, 9, 243, 14, 166, 9, 71, 5, 2, 1, 3, 3, 2, 0, 2, 1, 13, 9, 120, 6, 3, 6, 4, 0, 29, 9, 41, 6, 2, 3, 9, 0, 10, 10, 47, 15, 199, 7, 137, 9, 54, 7, 2, 7, 17, 9, 57, 21, 2, 13, 123, 5, 4, 0, 2, 1, 2, 6, 2, 0, 9, 9, 49, 4, 2, 1, 2, 4, 9, 9, 55, 9, 7, 0, 259, 3, 10, 1, 2, 0, 49, 6, 4, 4, 14, 10, 5350, 0, 7, 14, 11465, 27, 2343, 9, 87, 9, 39, 4, 60, 6, 26, 9, 535, 9, 470, 0, 2, 54, 8, 3, 82, 0, 12, 1, 19628, 1, 4178, 9, 519, 45, 3, 22, 481, 1, 61, 4, 4, 5, 9, 7, 3, 6, 31, 3, 149, 2, 12, 2, 9, 1, 3, 0, 33, 1, 1357, 49, 513, 54, 5, 49, 9, 0, 15, 0, 23, 4, 2, 14, 1361, 6, 2, 16, 3, 6, 2, 1, 2, 4, 101, 0, 161, 6, 10, 9, 357, 0, 62, 13, 499, 13, 245, 1, 2, 9, 233, 0, 3, 0, 8, 1, 6, 0, 475, 6, 110, 6, 6, 9, 4759, 9, 787719, 239];
  var astralIdentifierStartCodes = [0, 11, 2, 25, 2, 18, 2, 1, 2, 14, 3, 13, 35, 122, 70, 52, 268, 28, 4, 48, 48, 31, 14, 29, 6, 37, 11, 29, 3, 35, 5, 7, 2, 4, 43, 157, 19, 35, 5, 35, 5, 39, 9, 51, 13, 10, 2, 14, 2, 6, 2, 1, 2, 10, 2, 14, 2, 6, 2, 1, 4, 51, 13, 310, 10, 21, 11, 7, 25, 5, 2, 41, 2, 13, 65, 5, 3, 0, 2, 43, 2, 1, 4, 0, 3, 22, 11, 22, 10, 30, 66, 18, 2, 1, 11, 21, 11, 25, 7, 25, 39, 55, 7, 1, 65, 0, 16, 3, 2, 2, 2, 28, 43, 28, 4, 28, 36, 7, 2, 27, 28, 53, 11, 21, 11, 18, 14, 17, 111, 72, 56, 50, 14, 50, 14, 35, 39, 27, 10, 22, 251, 41, 7, 1, 17, 5, 18, 21, 18, 28, 11, 0, 9, 21, 43, 17, 47, 20, 28, 22, 13, 52, 58, 1, 3, 0, 14, 44, 33, 24, 27, 35, 30, 0, 3, 0, 9, 34, 4, 0, 13, 47, 15, 3, 22, 0, 2, 0, 36, 17, 2, 24, 20, 1, 64, 6, 2, 0, 2, 3, 2, 14, 2, 9, 8, 46, 39, 7, 3, 1, 3, 21, 2, 6, 2, 1, 2, 4, 4, 0, 19, 0, 13, 4, 31, 9, 2, 0, 3, 0, 2, 37, 2, 0, 26, 0, 2, 0, 45, 52, 19, 3, 21, 2, 31, 47, 21, 1, 2, 0, 185, 46, 42, 3, 37, 47, 21, 0, 60, 42, 14, 0, 72, 26, 38, 6, 186, 43, 117, 63, 32, 7, 3, 0, 3, 7, 2, 1, 2, 23, 16, 0, 2, 0, 95, 7, 3, 38, 17, 0, 2, 0, 29, 0, 11, 39, 8, 0, 22, 0, 12, 45, 20, 0, 19, 72, 18, 0, 182, 32, 32, 8, 2, 36, 18, 0, 50, 29, 113, 6, 2, 1, 2, 37, 22, 0, 26, 5, 2, 1, 2, 31, 15, 0, 24, 43, 22, 0, 239, 18, 16, 0, 2, 12, 2, 33, 125, 0, 80, 921, 103, 111, 6, 206, 13, 310, 2314, 96, 16, 1071, 18, 5, 26, 3994, 6, 582, 6842, 29, 1763, 568, 8, 30, 18, 78, 18, 29, 19, 47, 17, 3, 32, 20, 6, 18, 433, 44, 212, 63, 33, 24, 3, 24, 45, 74, 6, 0, 67, 12, 65, 1, 2, 0, 15, 4, 10, 7386, 37, 33, 96, 114, 14, 913, 15, 50, 7710, 3, 2, 6, 2, 1, 2, 296, 10, 0, 30, 2, 3, 0, 15, 4, 8, 395, 2309, 106, 6, 12, 4, 8, 8, 9, 5991, 84, 2, 70, 2, 1, 3, 0, 3, 1, 3, 3, 2, 11, 2, 0, 2, 6, 2, 64, 2, 3, 3, 7, 2, 6, 2, 27, 2, 3, 2, 4, 2, 0, 4, 6, 2, 340, 2, 24, 2, 24, 2, 30, 2, 24, 2, 30, 2, 24, 2, 30, 2, 24, 2, 30, 2, 24, 2, 7, 1845, 129, 15, 6, 55, 50, 49, 61, 147, 44, 11, 6, 17, 0, 322, 29, 19, 43, 485, 27, 229, 29, 3, 0, 208, 30, 2, 2, 2, 1, 2, 6, 3, 4, 10, 1, 225, 6, 2, 3, 2, 1, 2, 14, 2, 196, 60, 67, 8, 0, 1205, 3, 2, 26, 2, 1, 2, 0, 3, 0, 2, 9, 2, 3, 2, 0, 2, 0, 7, 0, 5, 0, 2, 0, 2, 0, 2, 2, 2, 1, 2, 0, 3, 0, 2, 0, 2, 0, 2, 0, 2, 0, 2, 1, 2, 0, 3, 3, 2, 6, 2, 3, 2, 3, 2, 0, 2, 9, 2, 16, 6, 2, 2, 4, 2, 16, 4421, 42719, 33, 4382, 2, 5773, 3, 7472, 16, 621, 2467, 541, 1507, 4938, 6, 8489, 39815, 11327];
  var nonASCIIidentifierChars = "\u200C\u200D\xB7\u0300-\u036F\u0387\u0483-\u0487\u0591-\u05BD\u05BF\u05C1\u05C2\u05C4\u05C5\u05C7-\u05C9\u0610-\u061A\u064B-\u0669\u0670\u06D6-\u06DC\u06DF-\u06E4\u06E7\u06E8\u06EA-\u06ED\u06F0-\u06F9\u0711\u0730-\u074A\u07A6-\u07B0\u07C0-\u07C9\u07EB-\u07F3\u07FD\u0816-\u0819\u081B-\u0823\u0825-\u0827\u0829-\u082D\u0859-\u085B\u0897-\u089F\u08CA-\u08E1\u08E3-\u0903\u093A-\u093C\u093E-\u094F\u0951-\u0957\u0962\u0963\u0966-\u096F\u0981-\u0983\u09BC\u09BE-\u09C4\u09C7\u09C8\u09CB-\u09CD\u09D7\u09E2\u09E3\u09E6-\u09EF\u09FE\u0A01-\u0A03\u0A3C\u0A3E-\u0A42\u0A47\u0A48\u0A4B-\u0A4D\u0A51\u0A66-\u0A71\u0A75\u0A81-\u0A83\u0ABC\u0ABE-\u0AC5\u0AC7-\u0AC9\u0ACB-\u0ACD\u0AE2\u0AE3\u0AE6-\u0AEF\u0AFA-\u0AFF\u0B01-\u0B03\u0B3C\u0B3E-\u0B44\u0B47\u0B48\u0B4B-\u0B4D\u0B53-\u0B57\u0B62\u0B63\u0B66-\u0B6F\u0B82\u0BBE-\u0BC2\u0BC6-\u0BC8\u0BCA-\u0BCD\u0BD7\u0BE6-\u0BEF\u0C00-\u0C04\u0C3C\u0C3E-\u0C44\u0C46-\u0C48\u0C4A-\u0C4D\u0C55\u0C56\u0C62\u0C63\u0C66-\u0C6F\u0C81-\u0C83\u0CBC\u0CBE-\u0CC4\u0CC6-\u0CC8\u0CCA-\u0CCD\u0CD5\u0CD6\u0CE2\u0CE3\u0CE6-\u0CEF\u0CF3\u0D00-\u0D03\u0D3B\u0D3C\u0D3E-\u0D44\u0D46-\u0D48\u0D4A-\u0D4D\u0D57\u0D62\u0D63\u0D66-\u0D6F\u0D81-\u0D83\u0DCA\u0DCF-\u0DD4\u0DD6\u0DD8-\u0DDF\u0DE6-\u0DEF\u0DF2\u0DF3\u0E31\u0E34-\u0E3A\u0E47-\u0E4E\u0E50-\u0E59\u0EB1\u0EB4-\u0EBC\u0EC8-\u0ECE\u0ED0-\u0ED9\u0F18\u0F19\u0F20-\u0F29\u0F35\u0F37\u0F39\u0F3E\u0F3F\u0F71-\u0F84\u0F86\u0F87\u0F8D-\u0F97\u0F99-\u0FBC\u0FC6\u102B-\u103E\u1040-\u1049\u1056-\u1059\u105E-\u1060\u1062-\u1064\u1067-\u106D\u1071-\u1074\u1082-\u108D\u108F-\u109D\u135D-\u135F\u1369-\u1371\u1712-\u1715\u1732-\u1734\u1752\u1753\u1772\u1773\u17B4-\u17D3\u17DD\u17E0-\u17E9\u180B-\u180D\u180F-\u1819\u18A9\u1920-\u192B\u1930-\u193B\u1946-\u194F\u19D0-\u19DA\u1A17-\u1A1B\u1A55-\u1A5E\u1A60-\u1A7C\u1A7F-\u1A89\u1A90-\u1A99\u1AB0-\u1ABD\u1ABF-\u1AF0\u1B00-\u1B04\u1B34-\u1B44\u1B50-\u1B59\u1B6B-\u1B73\u1B80-\u1B82\u1BA1-\u1BAD\u1BB0-\u1BB9\u1BE6-\u1BF3\u1C24-\u1C37\u1C40-\u1C49\u1C50-\u1C59\u1CD0-\u1CD2\u1CD4-\u1CE8\u1CED\u1CF4\u1CF7-\u1CF9\u1DC0-\u1DFF\u200C\u200D\u203F\u2040\u2054\u20D0-\u20DC\u20E1\u20E5-\u20F0\u2CEF-\u2CF1\u2D7F\u2DE0-\u2DFF\u302A-\u302F\u3099\u309A\u30FB\uA620-\uA629\uA66F\uA674-\uA67D\uA69E\uA69F\uA6F0\uA6F1\uA802\uA806\uA80B\uA823-\uA827\uA82C\uA880\uA881\uA8B4-\uA8C5\uA8D0-\uA8D9\uA8E0-\uA8F1\uA8FF-\uA909\uA926-\uA92D\uA947-\uA953\uA980-\uA983\uA9B3-\uA9C0\uA9D0-\uA9D9\uA9E5\uA9F0-\uA9F9\uAA29-\uAA36\uAA43\uAA4C\uAA4D\uAA50-\uAA59\uAA7B-\uAA7D\uAAB0\uAAB2-\uAAB4\uAAB7\uAAB8\uAABE\uAABF\uAAC1\uAAEB-\uAAEF\uAAF5\uAAF6\uABE3-\uABEA\uABEC\uABED\uABF0-\uABF9\uFB1E\uFE00-\uFE0F\uFE20-\uFE2F\uFE33\uFE34\uFE4D-\uFE4F\uFF10-\uFF19\uFF3F\uFF65";
  var nonASCIIidentifierStartChars = "\xAA\xB5\xBA\xC0-\xD6\xD8-\xF6\xF8-\u02C1\u02C6-\u02D1\u02E0-\u02E4\u02EC\u02EE\u0370-\u0374\u0376\u0377\u037A-\u037D\u037F\u0386\u0388-\u038A\u038C\u038E-\u03A1\u03A3-\u03F5\u03F7-\u0481\u048A-\u052F\u0531-\u0556\u0558\u0559\u0560-\u0588\u058B\u058C\u05D0-\u05EA\u05EF-\u05F2\u0620-\u064A\u066E\u066F\u0671-\u06D3\u06D5\u06E5\u06E6\u06EE\u06EF\u06FA-\u06FC\u06FF\u0710\u0712-\u072F\u074D-\u07A5\u07B1\u07CA-\u07EA\u07F4\u07F5\u07FA\u0800-\u0815\u081A\u0824\u0828\u0840-\u0858\u0860-\u086A\u0870-\u0887\u0889-\u088F\u08A0-\u08C9\u0904-\u0939\u093D\u0950\u0958-\u0961\u0971-\u0980\u0985-\u098C\u098F\u0990\u0993-\u09A8\u09AA-\u09B0\u09B2\u09B6-\u09B9\u09BD\u09CE\u09DC\u09DD\u09DF-\u09E1\u09F0\u09F1\u09FC\u0A05-\u0A0A\u0A0F\u0A10\u0A13-\u0A28\u0A2A-\u0A30\u0A32\u0A33\u0A35\u0A36\u0A38\u0A39\u0A59-\u0A5C\u0A5E\u0A72-\u0A74\u0A85-\u0A8D\u0A8F-\u0A91\u0A93-\u0AA8\u0AAA-\u0AB0\u0AB2\u0AB3\u0AB5-\u0AB9\u0ABD\u0AD0\u0AE0\u0AE1\u0AF9\u0B05-\u0B0C\u0B0F\u0B10\u0B13-\u0B28\u0B2A-\u0B30\u0B32\u0B33\u0B35-\u0B39\u0B3D\u0B5C\u0B5D\u0B5F-\u0B61\u0B71\u0B83\u0B85-\u0B8A\u0B8E-\u0B90\u0B92-\u0B95\u0B99\u0B9A\u0B9C\u0B9E\u0B9F\u0BA3\u0BA4\u0BA8-\u0BAA\u0BAE-\u0BB9\u0BD0\u0C05-\u0C0C\u0C0E-\u0C10\u0C12-\u0C28\u0C2A-\u0C39\u0C3D\u0C58-\u0C5A\u0C5C\u0C5D\u0C60\u0C61\u0C80\u0C85-\u0C8C\u0C8E-\u0C90\u0C92-\u0CA8\u0CAA-\u0CB3\u0CB5-\u0CB9\u0CBD\u0CDC-\u0CDE\u0CE0\u0CE1\u0CF1\u0CF2\u0D04-\u0D0C\u0D0E-\u0D10\u0D12-\u0D3A\u0D3D\u0D4E\u0D54-\u0D56\u0D5F-\u0D61\u0D7A-\u0D7F\u0D85-\u0D96\u0D9A-\u0DB1\u0DB3-\u0DBB\u0DBD\u0DC0-\u0DC6\u0E01-\u0E30\u0E32\u0E33\u0E40-\u0E46\u0E81\u0E82\u0E84\u0E86-\u0E8A\u0E8C-\u0EA3\u0EA5\u0EA7-\u0EB0\u0EB2\u0EB3\u0EBD\u0EC0-\u0EC4\u0EC6\u0EDC-\u0EDF\u0F00\u0F40-\u0F47\u0F49-\u0F6C\u0F88-\u0F8C\u1000-\u102A\u103F\u1050-\u1055\u105A-\u105D\u1061\u1065\u1066\u106E-\u1070\u1075-\u1081\u108E\u10A0-\u10C5\u10C7\u10CD\u10D0-\u10FA\u10FC-\u1248\u124A-\u124D\u1250-\u1256\u1258\u125A-\u125D\u1260-\u1288\u128A-\u128D\u1290-\u12B0\u12B2-\u12B5\u12B8-\u12BE\u12C0\u12C2-\u12C5\u12C8-\u12D6\u12D8-\u1310\u1312-\u1315\u1318-\u135A\u1380-\u138F\u13A0-\u13F5\u13F8-\u13FD\u1401-\u166C\u166F-\u167F\u1681-\u169A\u16A0-\u16EA\u16EE-\u16F8\u1700-\u1711\u171F-\u1731\u1740-\u1751\u1760-\u176C\u176E-\u1770\u1780-\u17B3\u17D7\u17DC\u1820-\u1878\u1880-\u18A8\u18AA\u18B0-\u18F5\u1900-\u191E\u1950-\u196D\u1970-\u1974\u1980-\u19AB\u19B0-\u19C9\u1A00-\u1A16\u1A20-\u1A54\u1AA7\u1B05-\u1B33\u1B45-\u1B4C\u1B83-\u1BA0\u1BAE\u1BAF\u1BBA-\u1BE5\u1C00-\u1C23\u1C4D-\u1C4F\u1C5A-\u1C7D\u1C80-\u1C8A\u1C90-\u1CBA\u1CBD-\u1CBF\u1CE9-\u1CEC\u1CEE-\u1CF3\u1CF5\u1CF6\u1CFA\u1D00-\u1DBF\u1E00-\u1F15\u1F18-\u1F1D\u1F20-\u1F45\u1F48-\u1F4D\u1F50-\u1F57\u1F59\u1F5B\u1F5D\u1F5F-\u1F7D\u1F80-\u1FB4\u1FB6-\u1FBC\u1FBE\u1FC2-\u1FC4\u1FC6-\u1FCC\u1FD0-\u1FD3\u1FD6-\u1FDB\u1FE0-\u1FEC\u1FF2-\u1FF4\u1FF6-\u1FFC\u2071\u207F\u208F-\u209F\u2102\u2107\u210A-\u2113\u2115\u2118-\u211D\u2124\u2126\u2128\u212A-\u2139\u213C-\u213F\u2145-\u2149\u214E\u2160-\u2188\u2C00-\u2CE4\u2CEB-\u2CEE\u2CF2\u2CF3\u2D00-\u2D25\u2D27\u2D2D\u2D30-\u2D67\u2D6F\u2D80-\u2D96\u2DA0-\u2DA6\u2DA8-\u2DAE\u2DB0-\u2DB6\u2DB8-\u2DBE\u2DC0-\u2DC6\u2DC8-\u2DCE\u2DD0-\u2DD6\u2DD8-\u2DDE\u3005-\u3007\u3021-\u3029\u3031-\u3035\u3038-\u303C\u3041-\u3096\u309B-\u309F\u30A1-\u30FA\u30FC-\u30FF\u3105-\u312F\u3131-\u318E\u31A0-\u31BF\u31F0-\u31FF\u3400-\u4DBF\u4E00-\uA48C\uA4D0-\uA4FD\uA500-\uA60C\uA610-\uA61F\uA62A\uA62B\uA640-\uA66E\uA67F-\uA69D\uA6A0-\uA6EF\uA717-\uA71F\uA722-\uA788\uA78B-\uA7DD\uA7E2\uA7F1-\uA801\uA803-\uA805\uA807-\uA80A\uA80C-\uA822\uA840-\uA873\uA882-\uA8B3\uA8F2-\uA8F7\uA8FB\uA8FD\uA8FE\uA90A-\uA925\uA930-\uA946\uA960-\uA97C\uA984-\uA9B2\uA9CF\uA9E0-\uA9E4\uA9E6-\uA9EF\uA9FA-\uA9FE\uAA00-\uAA28\uAA40-\uAA42\uAA44-\uAA4B\uAA60-\uAA76\uAA7A\uAA7E-\uAAAF\uAAB1\uAAB5\uAAB6\uAAB9-\uAABD\uAAC0\uAAC2\uAADB-\uAADD\uAAE0-\uAAEA\uAAF2-\uAAF4\uAB01-\uAB06\uAB09-\uAB0E\uAB11-\uAB16\uAB20-\uAB26\uAB28-\uAB2E\uAB30-\uAB5A\uAB5C-\uAB69\uAB6C\uAB6D\uAB70-\uABE2\uAC00-\uD7A3\uD7B0-\uD7C6\uD7CB-\uD7FB\uF900-\uFA6D\uFA70-\uFAD9\uFB00-\uFB06\uFB13-\uFB17\uFB1D\uFB1F-\uFB28\uFB2A-\uFB36\uFB38-\uFB3C\uFB3E\uFB40\uFB41\uFB43\uFB44\uFB46-\uFBB1\uFBD3-\uFD3D\uFD50-\uFD8F\uFD92-\uFDC7\uFDF0-\uFDFB\uFE70-\uFE74\uFE76-\uFEFC\uFF21-\uFF3A\uFF41-\uFF5A\uFF66-\uFFBE\uFFC2-\uFFC7\uFFCA-\uFFCF\uFFD2-\uFFD7\uFFDA-\uFFDC";
  var reservedWords = {
    3: "abstract boolean byte char class double enum export extends final float goto implements import int interface long native package private protected public short static super synchronized throws transient volatile",
    5: "class enum extends super const export import",
    6: "enum",
    strict: "implements interface let package private protected public static yield",
    strictBind: "eval arguments"
  };
  var ecma5AndLessKeywords = "break case catch continue debugger default do else finally for function if return switch throw try var while with null true false instanceof typeof void delete new in this";
  var keywords$1 = {
    5: ecma5AndLessKeywords,
    "5module": ecma5AndLessKeywords + " export import",
    6: ecma5AndLessKeywords + " const class extends export import super"
  };
  var keywordRelationalOperator = /^in(stanceof)?$/;
  var nonASCIIidentifierStart = new RegExp("[" + nonASCIIidentifierStartChars + "]");
  var nonASCIIidentifier = new RegExp("[" + nonASCIIidentifierStartChars + nonASCIIidentifierChars + "]");
  function isInAstralSet(code, set) {
    var pos = 65536;
    for (var i2 = 0; i2 < set.length; i2 += 2) {
      pos += set[i2];
      if (pos > code) {
        return false;
      }
      pos += set[i2 + 1];
      if (pos >= code) {
        return true;
      }
    }
    return false;
  }
  function isIdentifierStart(code, astral) {
    if (code < 65) {
      return code === 36;
    }
    if (code < 91) {
      return true;
    }
    if (code < 97) {
      return code === 95;
    }
    if (code < 123) {
      return true;
    }
    if (code <= 65535) {
      return code >= 170 && nonASCIIidentifierStart.test(String.fromCharCode(code));
    }
    if (astral === false) {
      return false;
    }
    return isInAstralSet(code, astralIdentifierStartCodes);
  }
  function isIdentifierChar(code, astral) {
    if (code < 48) {
      return code === 36;
    }
    if (code < 58) {
      return true;
    }
    if (code < 65) {
      return false;
    }
    if (code < 91) {
      return true;
    }
    if (code < 97) {
      return code === 95;
    }
    if (code < 123) {
      return true;
    }
    if (code <= 65535) {
      return code >= 170 && nonASCIIidentifier.test(String.fromCharCode(code));
    }
    if (astral === false) {
      return false;
    }
    return isInAstralSet(code, astralIdentifierStartCodes) || isInAstralSet(code, astralIdentifierCodes);
  }
  var TokenType = function TokenType2(label, conf) {
    if (conf === void 0) conf = {};
    this.label = label;
    this.keyword = conf.keyword;
    this.beforeExpr = !!conf.beforeExpr;
    this.startsExpr = !!conf.startsExpr;
    this.isLoop = !!conf.isLoop;
    this.isAssign = !!conf.isAssign;
    this.prefix = !!conf.prefix;
    this.postfix = !!conf.postfix;
    this.binop = conf.binop || null;
    this.updateContext = null;
  };
  function binop(name, prec) {
    return new TokenType(name, { beforeExpr: true, binop: prec });
  }
  var beforeExpr = { beforeExpr: true };
  var startsExpr = { startsExpr: true };
  var keywords = {};
  function kw(name, options) {
    if (options === void 0) options = {};
    options.keyword = name;
    return keywords[name] = new TokenType(name, options);
  }
  var types$1 = {
    num: new TokenType("num", startsExpr),
    regexp: new TokenType("regexp", startsExpr),
    string: new TokenType("string", startsExpr),
    name: new TokenType("name", startsExpr),
    privateId: new TokenType("privateId", startsExpr),
    eof: new TokenType("eof"),
    // Punctuation token types.
    bracketL: new TokenType("[", { beforeExpr: true, startsExpr: true }),
    bracketR: new TokenType("]"),
    braceL: new TokenType("{", { beforeExpr: true, startsExpr: true }),
    braceR: new TokenType("}"),
    parenL: new TokenType("(", { beforeExpr: true, startsExpr: true }),
    parenR: new TokenType(")"),
    comma: new TokenType(",", beforeExpr),
    semi: new TokenType(";", beforeExpr),
    colon: new TokenType(":", beforeExpr),
    dot: new TokenType("."),
    question: new TokenType("?", beforeExpr),
    questionDot: new TokenType("?."),
    arrow: new TokenType("=>", beforeExpr),
    template: new TokenType("template"),
    invalidTemplate: new TokenType("invalidTemplate"),
    ellipsis: new TokenType("...", beforeExpr),
    backQuote: new TokenType("`", startsExpr),
    dollarBraceL: new TokenType("${", { beforeExpr: true, startsExpr: true }),
    // Operators. These carry several kinds of properties to help the
    // parser use them properly (the presence of these properties is
    // what categorizes them as operators).
    //
    // `binop`, when present, specifies that this operator is a binary
    // operator, and will refer to its precedence.
    //
    // `prefix` and `postfix` mark the operator as a prefix or postfix
    // unary operator.
    //
    // `isAssign` marks all of `=`, `+=`, `-=` etcetera, which act as
    // binary operators with a very low precedence, that should result
    // in AssignmentExpression nodes.
    eq: new TokenType("=", { beforeExpr: true, isAssign: true }),
    assign: new TokenType("_=", { beforeExpr: true, isAssign: true }),
    incDec: new TokenType("++/--", { prefix: true, postfix: true, startsExpr: true }),
    prefix: new TokenType("!/~", { beforeExpr: true, prefix: true, startsExpr: true }),
    logicalOR: binop("||", 1),
    logicalAND: binop("&&", 2),
    bitwiseOR: binop("|", 3),
    bitwiseXOR: binop("^", 4),
    bitwiseAND: binop("&", 5),
    equality: binop("==/!=/===/!==", 6),
    relational: binop("</>/<=/>=", 7),
    bitShift: binop("<</>>/>>>", 8),
    plusMin: new TokenType("+/-", { beforeExpr: true, binop: 9, prefix: true, startsExpr: true }),
    modulo: binop("%", 10),
    star: binop("*", 10),
    slash: binop("/", 10),
    starstar: new TokenType("**", { beforeExpr: true }),
    coalesce: binop("??", 1),
    // Keyword token types.
    _break: kw("break"),
    _case: kw("case", beforeExpr),
    _catch: kw("catch"),
    _continue: kw("continue"),
    _debugger: kw("debugger"),
    _default: kw("default", beforeExpr),
    _do: kw("do", { isLoop: true, beforeExpr: true }),
    _else: kw("else", beforeExpr),
    _finally: kw("finally"),
    _for: kw("for", { isLoop: true }),
    _function: kw("function", startsExpr),
    _if: kw("if"),
    _return: kw("return", beforeExpr),
    _switch: kw("switch"),
    _throw: kw("throw", beforeExpr),
    _try: kw("try"),
    _var: kw("var"),
    _const: kw("const"),
    _while: kw("while", { isLoop: true }),
    _with: kw("with"),
    _new: kw("new", { beforeExpr: true, startsExpr: true }),
    _this: kw("this", startsExpr),
    _super: kw("super", startsExpr),
    _class: kw("class", startsExpr),
    _extends: kw("extends", beforeExpr),
    _export: kw("export"),
    _import: kw("import", startsExpr),
    _null: kw("null", startsExpr),
    _true: kw("true", startsExpr),
    _false: kw("false", startsExpr),
    _in: kw("in", { beforeExpr: true, binop: 7 }),
    _instanceof: kw("instanceof", { beforeExpr: true, binop: 7 }),
    _typeof: kw("typeof", { beforeExpr: true, prefix: true, startsExpr: true }),
    _void: kw("void", { beforeExpr: true, prefix: true, startsExpr: true }),
    _delete: kw("delete", { beforeExpr: true, prefix: true, startsExpr: true })
  };
  var lineBreak = /\r\n?|\n|\u2028|\u2029/;
  var lineBreakG = new RegExp(lineBreak.source, "g");
  function isNewLine(code) {
    return code === 10 || code === 13 || code === 8232 || code === 8233;
  }
  function nextLineBreak(code, from, end) {
    if (end === void 0) end = code.length;
    for (var i2 = from; i2 < end; i2++) {
      var next = code.charCodeAt(i2);
      if (isNewLine(next)) {
        return i2 < end - 1 && next === 13 && code.charCodeAt(i2 + 1) === 10 ? i2 + 2 : i2 + 1;
      }
    }
    return -1;
  }
  var nonASCIIwhitespace = /[\u1680\u2000-\u200a\u202f\u205f\u3000\ufeff]/;
  var skipWhiteSpace = /(?:\s|\/\/.*|\/\*[^]*?\*\/)*/g;
  var ref = Object.prototype;
  var hasOwnProperty = ref.hasOwnProperty;
  var toString = ref.toString;
  var hasOwn = Object.hasOwn || (function(obj, propName) {
    return hasOwnProperty.call(obj, propName);
  });
  var isArray = Array.isArray || (function(obj) {
    return toString.call(obj) === "[object Array]";
  });
  var regexpCache = /* @__PURE__ */ Object.create(null);
  function wordsRegexp(words) {
    return regexpCache[words] || (regexpCache[words] = new RegExp("^(?:" + words.replace(/ /g, "|") + ")$"));
  }
  function codePointToString(code) {
    if (code <= 65535) {
      return String.fromCharCode(code);
    }
    code -= 65536;
    return String.fromCharCode((code >> 10) + 55296, (code & 1023) + 56320);
  }
  var loneSurrogate = /(?:[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF])/;
  var Position = function Position2(line, col) {
    this.line = line;
    this.column = col;
  };
  Position.prototype.offset = function offset(n) {
    return new Position(this.line, this.column + n);
  };
  var SourceLocation = function SourceLocation2(p, start, end) {
    this.start = start;
    this.end = end;
    if (p.sourceFile !== null) {
      this.source = p.sourceFile;
    }
  };
  function getLineInfo(input, offset2) {
    for (var line = 1, cur = 0; ; ) {
      var nextBreak = nextLineBreak(input, cur, offset2);
      if (nextBreak < 0) {
        return new Position(line, offset2 - cur);
      }
      ++line;
      cur = nextBreak;
    }
  }
  var defaultOptions = {
    // `ecmaVersion` indicates the ECMAScript version to parse. Must be
    // either 3, 5, 6 (or 2015), 7 (2016), 8 (2017), 9 (2018), 10
    // (2019), 11 (2020), 12 (2021), 13 (2022), 14 (2023), or `"latest"`
    // (the latest version the library supports). This influences
    // support for strict mode, the set of reserved words, and support
    // for new syntax features.
    ecmaVersion: null,
    // `sourceType` indicates the mode the code should be parsed in.
    // Can be either `"script"`, `"module"` or `"commonjs"`. This influences global
    // strict mode and parsing of `import` and `export` declarations.
    sourceType: "script",
    // When set to true, enable strict parsing mode even if `sourceType`
    // is `"script"`.
    strict: false,
    // `onInsertedSemicolon` can be a callback that will be called when
    // a semicolon is automatically inserted. It will be passed the
    // position of the inserted semicolon as an offset, and if
    // `locations` is enabled, it is given the location as a `{line,
    // column}` object as second argument.
    onInsertedSemicolon: null,
    // `onTrailingComma` is similar to `onInsertedSemicolon`, but for
    // trailing commas.
    onTrailingComma: null,
    // By default, reserved words are only enforced if ecmaVersion >= 5.
    // Set `allowReserved` to a boolean value to explicitly turn this on
    // an off. When this option has the value "never", reserved words
    // and keywords can also not be used as property names.
    allowReserved: null,
    // When enabled, a return at the top level is not considered an
    // error.
    allowReturnOutsideFunction: false,
    // When enabled, import/export statements are not constrained to
    // appearing at the top of the program, and an import.meta expression
    // in a script isn't considered an error.
    allowImportExportEverywhere: false,
    // By default, await identifiers are allowed to appear at the top-level scope only if ecmaVersion >= 2022.
    // When enabled, await identifiers are allowed to appear at the top-level scope,
    // but they are still not allowed in non-async functions.
    allowAwaitOutsideFunction: null,
    // When enabled, super identifiers are not constrained to
    // appearing in methods and do not raise an error when they appear elsewhere.
    allowSuperOutsideMethod: null,
    // When enabled, hashbang directive in the beginning of file is
    // allowed and treated as a line comment. Enabled by default when
    // `ecmaVersion` >= 2023.
    allowHashBang: false,
    // By default, the parser will verify that private properties are
    // only used in places where they are valid and have been declared.
    // Set this to false to turn such checks off.
    checkPrivateFields: true,
    // When `locations` is on, `loc` properties holding objects with
    // `start` and `end` properties in `{line, column}` form (with
    // line being 1-based and column 0-based) will be attached to the
    // nodes.
    locations: false,
    // Pass an optional `{line, column}` object to use for the start of
    // the parse. This is mostly useful when using `parseExpressionAt`
    // with `locations: true`, to prevent the parser from having to
    // determine the line position at the start position.
    startLocation: null,
    // A function can be passed as `onToken` option, which will
    // cause Acorn to call that function with object in the same
    // format as tokens returned from `tokenizer().getToken()`. Note
    // that you are not allowed to call the parser from the
    // callback—that will corrupt its internal state.
    onToken: null,
    // A function can be passed as `onComment` option, which will
    // cause Acorn to call that function with `(block, text, start,
    // end)` parameters whenever a comment is skipped. `block` is a
    // boolean indicating whether this is a block (`/* */`) comment,
    // `text` is the content of the comment, and `start` and `end` are
    // character offsets that denote the start and end of the comment.
    // When the `locations` option is on, two more parameters are
    // passed, the full `{line, column}` locations of the start and
    // end of the comments. Note that you are not allowed to call the
    // parser from the callback—that will corrupt its internal state.
    // When this option has an array as value, objects representing the
    // comments are pushed to it.
    onComment: null,
    // Nodes have their start and end characters offsets recorded in
    // `start` and `end` properties (directly on the node, rather than
    // the `loc` object, which holds line/column data. To also add a
    // [semi-standardized][range] `range` property holding a `[start,
    // end]` array with the same numbers, set the `ranges` option to
    // `true`.
    //
    // [range]: https://bugzilla.mozilla.org/show_bug.cgi?id=745678
    ranges: false,
    // It is possible to parse multiple files into a single AST by
    // passing the tree produced by parsing the first file as
    // `program` option in subsequent parses. This will add the
    // toplevel forms of the parsed file to the `Program` (top) node
    // of an existing parse tree.
    program: null,
    // When `locations` is on, you can pass this to record the source
    // file in every node's `loc` object.
    sourceFile: null,
    // This value, if given, is stored in every node, whether
    // `locations` is on or off.
    directSourceFile: null,
    // When enabled, parenthesized expressions are represented by
    // (non-standard) ParenthesizedExpression nodes
    preserveParens: false
  };
  var warnedAboutEcmaVersion = false;
  function getOptions(opts) {
    var options = {};
    for (var opt in defaultOptions) {
      options[opt] = opts && hasOwn(opts, opt) ? opts[opt] : defaultOptions[opt];
    }
    if (options.ecmaVersion === "latest") {
      options.ecmaVersion = 1e8;
    } else if (options.ecmaVersion == null) {
      if (!warnedAboutEcmaVersion && typeof console === "object" && console.warn) {
        warnedAboutEcmaVersion = true;
        console.warn("Since Acorn 8.0.0, options.ecmaVersion is required.\nDefaulting to 2020, but this will stop working in the future.");
      }
      options.ecmaVersion = 11;
    } else if (options.ecmaVersion >= 2015) {
      options.ecmaVersion -= 2009;
    }
    if (options.allowReserved == null) {
      options.allowReserved = options.ecmaVersion < 5;
    }
    if (!opts || opts.allowHashBang == null) {
      options.allowHashBang = options.ecmaVersion >= 14;
    }
    if (isArray(options.onToken)) {
      var tokens2 = options.onToken;
      options.onToken = function(token) {
        return tokens2.push(token);
      };
    }
    if (isArray(options.onComment)) {
      options.onComment = pushComment(options, options.onComment);
    }
    if (options.sourceType === "commonjs" && options.allowAwaitOutsideFunction) {
      throw new Error("Cannot use allowAwaitOutsideFunction with sourceType: commonjs");
    }
    return options;
  }
  function pushComment(options, array) {
    return function(block, text2, start, end, startLoc, endLoc) {
      var comment = {
        type: block ? "Block" : "Line",
        value: text2,
        start,
        end
      };
      if (options.locations) {
        comment.loc = new SourceLocation(this, startLoc, endLoc);
      }
      if (options.ranges) {
        comment.range = [start, end];
      }
      array.push(comment);
    };
  }
  var SCOPE_TOP = 1;
  var SCOPE_FUNCTION = 2;
  var SCOPE_ASYNC = 4;
  var SCOPE_GENERATOR = 8;
  var SCOPE_ARROW = 16;
  var SCOPE_SIMPLE_CATCH = 32;
  var SCOPE_SUPER = 64;
  var SCOPE_DIRECT_SUPER = 128;
  var SCOPE_CLASS_STATIC_BLOCK = 256;
  var SCOPE_CLASS_FIELD_INIT = 512;
  var SCOPE_SWITCH = 1024;
  var SCOPE_VAR = SCOPE_TOP | SCOPE_FUNCTION | SCOPE_CLASS_STATIC_BLOCK;
  function functionFlags(async, generator) {
    return SCOPE_FUNCTION | (async ? SCOPE_ASYNC : 0) | (generator ? SCOPE_GENERATOR : 0);
  }
  var BIND_NONE = 0;
  var BIND_VAR = 1;
  var BIND_LEXICAL = 2;
  var BIND_FUNCTION = 3;
  var BIND_SIMPLE_CATCH = 4;
  var BIND_OUTSIDE = 5;
  var Parser = function Parser2(options, input, startPos) {
    this.options = options = getOptions(options);
    this.sourceFile = options.sourceFile;
    this.keywords = wordsRegexp(keywords$1[options.ecmaVersion >= 6 ? 6 : options.sourceType === "module" ? "5module" : 5]);
    var reserved = "";
    if (options.allowReserved !== true) {
      reserved = reservedWords[options.ecmaVersion >= 6 ? 6 : options.ecmaVersion === 5 ? 5 : 3];
      if (options.sourceType === "module") {
        reserved += " await";
      }
    }
    this.reservedWords = wordsRegexp(reserved);
    var reservedStrict = (reserved ? reserved + " " : "") + reservedWords.strict;
    this.reservedWordsStrict = wordsRegexp(reservedStrict);
    this.reservedWordsStrictBind = wordsRegexp(reservedStrict + " " + reservedWords.strictBind);
    this.input = String(input);
    this.containsEsc = false;
    this.pos = startPos || 0;
    this.curLine = 1;
    if (options.startLocation) {
      this.lineStart = this.pos - options.startLocation.column;
      this.curLine = options.startLocation.line;
    } else if (startPos) {
      this.lineStart = this.input.lastIndexOf("\n", startPos - 1) + 1;
      if (this.options.locations) {
        this.curLine = this.input.slice(0, this.lineStart).split(lineBreak).length;
      }
    } else {
      this.lineStart = 0;
    }
    this.type = types$1.eof;
    this.value = null;
    this.start = this.end = this.pos;
    this.startLoc = this.endLoc = this.curPosition();
    this.lastTokEndLoc = this.lastTokStartLoc = null;
    this.lastTokStart = this.lastTokEnd = this.pos;
    this.context = this.initialContext();
    this.exprAllowed = true;
    this.inModule = options.sourceType === "module";
    this.strict = this.inModule || options.strict === true || this.strictDirective(this.pos);
    this.potentialArrowAt = -1;
    this.potentialArrowInForAwait = false;
    this.yieldPos = this.awaitPos = this.awaitIdentPos = 0;
    this.labels = [];
    this.undefinedExports = /* @__PURE__ */ Object.create(null);
    if (this.pos === 0 && options.allowHashBang && this.input.slice(0, 2) === "#!") {
      this.skipLineComment(2);
    }
    this.scopeStack = [];
    this.enterScope(
      this.options.sourceType === "commonjs" ? SCOPE_FUNCTION : SCOPE_TOP
    );
    this.regexpState = null;
    this.privateNameStack = [];
  };
  var prototypeAccessors = { inFunction: { configurable: true }, inGenerator: { configurable: true }, inAsync: { configurable: true }, canAwait: { configurable: true }, allowReturn: { configurable: true }, allowSuper: { configurable: true }, allowDirectSuper: { configurable: true }, treatFunctionsAsVar: { configurable: true }, allowNewDotTarget: { configurable: true }, allowUsing: { configurable: true }, inClassStaticBlock: { configurable: true } };
  Parser.prototype.parse = function parse() {
    var this$1$1 = this;
    var node = this.options.program || this.startNode();
    this.nextToken();
    return this.catchStackOverflow(function() {
      return this$1$1.parseTopLevel(node);
    });
  };
  prototypeAccessors.inFunction.get = function() {
    return (this.currentVarScope().flags & SCOPE_FUNCTION) > 0;
  };
  prototypeAccessors.inGenerator.get = function() {
    return (this.currentVarScope().flags & SCOPE_GENERATOR) > 0;
  };
  prototypeAccessors.inAsync.get = function() {
    return (this.currentVarScope().flags & SCOPE_ASYNC) > 0;
  };
  prototypeAccessors.canAwait.get = function() {
    for (var i2 = this.scopeStack.length - 1; i2 >= 0; i2--) {
      var ref2 = this.scopeStack[i2];
      var flags = ref2.flags;
      if (flags & (SCOPE_CLASS_STATIC_BLOCK | SCOPE_CLASS_FIELD_INIT)) {
        return false;
      }
      if (flags & SCOPE_FUNCTION) {
        return (flags & SCOPE_ASYNC) > 0;
      }
    }
    return this.inModule && this.options.ecmaVersion >= 13 || this.options.allowAwaitOutsideFunction;
  };
  prototypeAccessors.allowReturn.get = function() {
    if (this.inFunction) {
      return true;
    }
    if (this.options.allowReturnOutsideFunction && this.currentVarScope().flags & SCOPE_TOP) {
      return true;
    }
    return false;
  };
  prototypeAccessors.allowSuper.get = function() {
    var ref2 = this.currentThisScope();
    var flags = ref2.flags;
    return (flags & SCOPE_SUPER) > 0 || this.options.allowSuperOutsideMethod;
  };
  prototypeAccessors.allowDirectSuper.get = function() {
    return (this.currentThisScope().flags & SCOPE_DIRECT_SUPER) > 0;
  };
  prototypeAccessors.treatFunctionsAsVar.get = function() {
    return this.treatFunctionsAsVarInScope(this.currentScope());
  };
  prototypeAccessors.allowNewDotTarget.get = function() {
    for (var i2 = this.scopeStack.length - 1; i2 >= 0; i2--) {
      var ref2 = this.scopeStack[i2];
      var flags = ref2.flags;
      if (flags & (SCOPE_CLASS_STATIC_BLOCK | SCOPE_CLASS_FIELD_INIT) || flags & SCOPE_FUNCTION && !(flags & SCOPE_ARROW)) {
        return true;
      }
    }
    return false;
  };
  prototypeAccessors.allowUsing.get = function() {
    var ref2 = this.currentScope();
    var flags = ref2.flags;
    if (flags & SCOPE_SWITCH) {
      return false;
    }
    if (!this.inModule && flags & SCOPE_TOP) {
      return false;
    }
    return true;
  };
  prototypeAccessors.inClassStaticBlock.get = function() {
    return (this.currentVarScope().flags & SCOPE_CLASS_STATIC_BLOCK) > 0;
  };
  Parser.extend = function extend() {
    var plugins = [], len = arguments.length;
    while (len--) plugins[len] = arguments[len];
    var cls = this;
    for (var i2 = 0; i2 < plugins.length; i2++) {
      cls = plugins[i2](cls);
    }
    return cls;
  };
  Parser.parse = function parse2(input, options) {
    return new this(options, input).parse();
  };
  Parser.parseExpressionAt = function parseExpressionAt(input, pos, options) {
    var parser = new this(options, input, pos);
    parser.nextToken();
    return parser.parseExpression();
  };
  Parser.tokenizer = function tokenizer(input, options) {
    return new this(options, input);
  };
  Object.defineProperties(Parser.prototype, prototypeAccessors);
  var pp$9 = Parser.prototype;
  var literal = /^(?:'((?:\\[^]|[^'\\])*?)'|"((?:\\[^]|[^"\\])*?)")/;
  pp$9.strictDirective = function(start) {
    if (this.options.ecmaVersion < 5) {
      return false;
    }
    for (; ; ) {
      skipWhiteSpace.lastIndex = start;
      start += skipWhiteSpace.exec(this.input)[0].length;
      var match = literal.exec(this.input.slice(start));
      if (!match) {
        return false;
      }
      if ((match[1] || match[2]) === "use strict") {
        skipWhiteSpace.lastIndex = start + match[0].length;
        var spaceAfter = skipWhiteSpace.exec(this.input), end = spaceAfter.index + spaceAfter[0].length;
        var next = this.input.charAt(end);
        return next === ";" || next === "}" || lineBreak.test(spaceAfter[0]) && !(/[(`.[+\-/*%<>=,?^&]/.test(next) || next === "!" && this.input.charAt(end + 1) === "=" || next === "i" && keywordOpAt(this, end));
      }
      start += match[0].length;
      skipWhiteSpace.lastIndex = start;
      start += skipWhiteSpace.exec(this.input)[0].length;
      if (this.input[start] === ";") {
        start++;
      }
    }
  };
  function keywordOpAt(parser, pos) {
    var end = pos + 1, stop2 = Math.min(parser.input.length, pos + 11);
    while (end < stop2) {
      var ch = parser.fullCharCodeAt(end);
      if (!isIdentifierChar(ch, true)) {
        break;
      }
      end += ch <= 65535 ? 1 : 2;
    }
    return end === pos + 2 && parser.input.slice(pos, end) === "in" || end === pos + 10 && parser.input.slice(pos, end) === "instanceof";
  }
  pp$9.eat = function(type) {
    if (this.type === type) {
      this.next();
      return true;
    } else {
      return false;
    }
  };
  pp$9.isContextual = function(name) {
    return this.type === types$1.name && this.value === name && !this.containsEsc;
  };
  pp$9.eatContextual = function(name) {
    if (!this.isContextual(name)) {
      return false;
    }
    this.next();
    return true;
  };
  pp$9.catchStackOverflow = function(f) {
    try {
      return f();
    } catch (e) {
      if (e instanceof Error && (/\bstack\b.*\b(exceeded|overflow)\b/i.test(e.message) || /\btoo much recursion\b/i.test(e.message))) {
        this.raise(this.start, "Not enough stack space to parse input");
      } else {
        throw e;
      }
    }
  };
  pp$9.expectContextual = function(name) {
    if (!this.eatContextual(name)) {
      this.unexpected();
    }
  };
  pp$9.canInsertSemicolon = function() {
    return this.type === types$1.eof || this.type === types$1.braceR || lineBreak.test(this.input.slice(this.lastTokEnd, this.start));
  };
  pp$9.insertSemicolon = function() {
    if (this.canInsertSemicolon()) {
      if (this.options.onInsertedSemicolon) {
        this.options.onInsertedSemicolon(this.lastTokEnd, this.lastTokEndLoc);
      }
      return true;
    }
  };
  pp$9.semicolon = function() {
    if (!this.eat(types$1.semi) && !this.insertSemicolon()) {
      this.unexpected();
    }
  };
  pp$9.afterTrailingComma = function(tokType, notNext) {
    if (this.type === tokType) {
      if (this.options.onTrailingComma) {
        this.options.onTrailingComma(this.lastTokStart, this.lastTokStartLoc);
      }
      if (!notNext) {
        this.next();
      }
      return true;
    }
  };
  pp$9.expect = function(type) {
    this.eat(type) || this.unexpected();
  };
  pp$9.unexpected = function(pos) {
    this.raise(pos != null ? pos : this.start, "Unexpected token");
  };
  var DestructuringErrors = function DestructuringErrors2() {
    this.shorthandAssign = this.trailingComma = this.parenthesizedAssign = this.parenthesizedBind = this.doubleProto = -1;
  };
  pp$9.checkPatternErrors = function(refDestructuringErrors, isAssign) {
    if (!refDestructuringErrors) {
      return;
    }
    if (refDestructuringErrors.trailingComma > -1) {
      this.raiseRecoverable(refDestructuringErrors.trailingComma, "Comma is not permitted after the rest element");
    }
    var parens = isAssign ? refDestructuringErrors.parenthesizedAssign : refDestructuringErrors.parenthesizedBind;
    if (parens > -1) {
      this.raiseRecoverable(parens, isAssign ? "Assigning to rvalue" : "Parenthesized pattern");
    }
  };
  pp$9.checkExpressionErrors = function(refDestructuringErrors, andThrow) {
    if (!refDestructuringErrors) {
      return false;
    }
    var shorthandAssign = refDestructuringErrors.shorthandAssign;
    var doubleProto = refDestructuringErrors.doubleProto;
    if (!andThrow) {
      return shorthandAssign >= 0 || doubleProto >= 0;
    }
    if (shorthandAssign >= 0) {
      this.raise(shorthandAssign, "Shorthand property assignments are valid only in destructuring patterns");
    }
    if (doubleProto >= 0) {
      this.raiseRecoverable(doubleProto, "Redefinition of __proto__ property");
    }
  };
  pp$9.checkYieldAwaitInDefaultParams = function() {
    if (this.yieldPos && (!this.awaitPos || this.yieldPos < this.awaitPos)) {
      this.raise(this.yieldPos, "Yield expression cannot be a default value");
    }
    if (this.awaitPos) {
      this.raise(this.awaitPos, "Await expression cannot be a default value");
    }
  };
  pp$9.isSimpleAssignTarget = function(expr) {
    if (expr.type === "ParenthesizedExpression") {
      return this.isSimpleAssignTarget(expr.expression);
    }
    return expr.type === "Identifier" || expr.type === "MemberExpression";
  };
  var pp$8 = Parser.prototype;
  pp$8.parseTopLevel = function(node) {
    var exports$1 = /* @__PURE__ */ Object.create(null);
    if (!node.body) {
      node.body = [];
    }
    while (this.type !== types$1.eof) {
      var stmt = this.parseStatement(null, true, exports$1);
      node.body.push(stmt);
    }
    if (this.inModule) {
      for (var i2 = 0, list3 = Object.keys(this.undefinedExports); i2 < list3.length; i2 += 1) {
        var name = list3[i2];
        this.raiseRecoverable(this.undefinedExports[name].start, "Export '" + name + "' is not defined");
      }
    }
    this.adaptDirectivePrologue(node.body);
    this.next();
    node.sourceType = this.options.sourceType === "commonjs" ? "script" : this.options.sourceType;
    return this.finishNode(node, "Program");
  };
  var loopLabel = { kind: "loop" };
  var switchLabel = { kind: "switch" };
  pp$8.isLet = function(context) {
    if (this.options.ecmaVersion < 6 || !this.isContextual("let")) {
      return false;
    }
    skipWhiteSpace.lastIndex = this.pos;
    var skip = skipWhiteSpace.exec(this.input);
    var next = this.pos + skip[0].length, nextCh = this.fullCharCodeAt(next);
    if (nextCh === 91 || nextCh === 92) {
      return true;
    }
    if (context) {
      return false;
    }
    if (nextCh === 123) {
      return true;
    }
    if (isIdentifierStart(nextCh)) {
      var start = next;
      do {
        next += nextCh <= 65535 ? 1 : 2;
      } while (isIdentifierChar(nextCh = this.fullCharCodeAt(next)));
      if (nextCh === 92) {
        return true;
      }
      var ident = this.input.slice(start, next);
      if (!keywordRelationalOperator.test(ident)) {
        return true;
      }
    }
    return false;
  };
  pp$8.isAsyncFunction = function() {
    if (this.options.ecmaVersion < 8 || !this.isContextual("async")) {
      return false;
    }
    skipWhiteSpace.lastIndex = this.pos;
    var skip = skipWhiteSpace.exec(this.input);
    var next = this.pos + skip[0].length, after;
    return !lineBreak.test(this.input.slice(this.pos, next)) && this.input.slice(next, next + 8) === "function" && (next + 8 === this.input.length || !(isIdentifierChar(after = this.fullCharCodeAt(next + 8)) || after === 92));
  };
  pp$8.isUsingKeyword = function(isAwaitUsing, isFor) {
    if (this.options.ecmaVersion < 17 || !this.isContextual(isAwaitUsing ? "await" : "using")) {
      return false;
    }
    skipWhiteSpace.lastIndex = this.pos;
    var skip = skipWhiteSpace.exec(this.input);
    var next = this.pos + skip[0].length;
    if (lineBreak.test(this.input.slice(this.pos, next))) {
      return false;
    }
    if (isAwaitUsing) {
      var usingEndPos = next + 5, after;
      if (this.input.slice(next, usingEndPos) !== "using" || usingEndPos === this.input.length || isIdentifierChar(after = this.fullCharCodeAt(usingEndPos)) || after === 92) {
        return false;
      }
      skipWhiteSpace.lastIndex = usingEndPos;
      var skipAfterUsing = skipWhiteSpace.exec(this.input);
      next = usingEndPos + skipAfterUsing[0].length;
      if (skipAfterUsing && lineBreak.test(this.input.slice(usingEndPos, next))) {
        return false;
      }
    }
    var ch = this.fullCharCodeAt(next);
    if (!isIdentifierStart(ch) && ch !== 92) {
      return false;
    }
    var idStart = next;
    do {
      next += ch <= 65535 ? 1 : 2;
    } while (isIdentifierChar(ch = this.fullCharCodeAt(next)));
    if (ch === 92) {
      return true;
    }
    var id = this.input.slice(idStart, next);
    if (keywordRelationalOperator.test(id)) {
      return false;
    }
    if (isFor && !isAwaitUsing && id === "of") {
      skipWhiteSpace.lastIndex = next;
      var skipAfterOf = skipWhiteSpace.exec(this.input);
      next = next + skipAfterOf[0].length;
      if (this.input.charCodeAt(next) !== 61 || // Check for ==, === and => operators
      (ch = this.input.charCodeAt(next + 1)) === 61 || ch === 62) {
        return false;
      }
    }
    return true;
  };
  pp$8.isAwaitUsing = function(isFor) {
    return this.isUsingKeyword(true, isFor);
  };
  pp$8.isUsing = function(isFor) {
    return this.isUsingKeyword(false, isFor);
  };
  pp$8.parseStatement = function(context, topLevel, exports$1) {
    var starttype = this.type, node = this.startNode(), kind;
    if (this.isLet(context)) {
      starttype = types$1._var;
      kind = "let";
    }
    switch (starttype) {
      case types$1._break:
      case types$1._continue:
        return this.parseBreakContinueStatement(node, starttype.keyword);
      case types$1._debugger:
        return this.parseDebuggerStatement(node);
      case types$1._do:
        return this.parseDoStatement(node);
      case types$1._for:
        return this.parseForStatement(node);
      case types$1._function:
        if (context && (this.strict || context !== "if" && context !== "label") && this.options.ecmaVersion >= 6) {
          this.unexpected();
        }
        return this.parseFunctionStatement(node, false, !context);
      case types$1._class:
        if (context) {
          this.unexpected();
        }
        return this.parseClass(node, true);
      case types$1._if:
        return this.parseIfStatement(node);
      case types$1._return:
        return this.parseReturnStatement(node);
      case types$1._switch:
        return this.parseSwitchStatement(node);
      case types$1._throw:
        return this.parseThrowStatement(node);
      case types$1._try:
        return this.parseTryStatement(node);
      case types$1._const:
      case types$1._var:
        kind = kind || this.value;
        if (context && kind !== "var") {
          this.unexpected();
        }
        return this.parseVarStatement(node, kind);
      case types$1._while:
        return this.parseWhileStatement(node);
      case types$1._with:
        return this.parseWithStatement(node);
      case types$1.braceL:
        return this.parseBlock(true, node);
      case types$1.semi:
        return this.parseEmptyStatement(node);
      case types$1._export:
      case types$1._import:
        if (this.options.ecmaVersion > 10 && starttype === types$1._import) {
          skipWhiteSpace.lastIndex = this.pos;
          var skip = skipWhiteSpace.exec(this.input);
          var next = this.pos + skip[0].length, nextCh = this.input.charCodeAt(next);
          if (nextCh === 40 || nextCh === 46) {
            return this.parseExpressionStatement(node, this.parseExpression());
          }
        }
        if (!this.options.allowImportExportEverywhere) {
          if (!topLevel) {
            this.raise(this.start, "'import' and 'export' may only appear at the top level");
          }
          if (!this.inModule) {
            this.raise(this.start, "'import' and 'export' may appear only with 'sourceType: module'");
          }
        }
        return starttype === types$1._import ? this.parseImport(node) : this.parseExport(node, exports$1);
      // If the statement does not start with a statement keyword or a
      // brace, it's an ExpressionStatement or LabeledStatement. We
      // simply start parsing an expression, and afterwards, if the
      // next token is a colon and the expression was a simple
      // Identifier node, we switch to interpreting it as a label.
      default:
        if (this.isAsyncFunction()) {
          if (context) {
            this.unexpected();
          }
          this.next();
          return this.parseFunctionStatement(node, true, !context);
        }
        var usingKind = this.isAwaitUsing(false) ? "await using" : this.isUsing(false) ? "using" : null;
        if (usingKind) {
          if (!this.allowUsing) {
            this.raise(this.start, "Using declaration cannot appear in the top level when source type is `script` or in the bare case statement");
          }
          if (context) {
            this.raise(this.start, "Using declaration is not allowed in single-statement positions");
          }
          if (usingKind === "await using") {
            if (!this.canAwait) {
              this.raise(this.start, "Await using cannot appear outside of async function");
            }
            this.next();
          }
          this.next();
          this.parseVar(node, false, usingKind);
          this.semicolon();
          return this.finishNode(node, "VariableDeclaration");
        }
        var maybeName = this.value, expr = this.parseExpression();
        if (starttype === types$1.name && expr.type === "Identifier" && this.eat(types$1.colon)) {
          return this.parseLabeledStatement(node, maybeName, expr, context);
        } else {
          return this.parseExpressionStatement(node, expr);
        }
    }
  };
  pp$8.parseBreakContinueStatement = function(node, keyword) {
    var isBreak = keyword === "break";
    this.next();
    if (this.eat(types$1.semi) || this.insertSemicolon()) {
      node.label = null;
    } else if (this.type !== types$1.name) {
      this.unexpected();
    } else {
      node.label = this.parseIdent();
      this.semicolon();
    }
    var i2 = 0;
    for (; i2 < this.labels.length; ++i2) {
      var lab = this.labels[i2];
      if (node.label == null || lab.name === node.label.name) {
        if (lab.kind != null && (isBreak || lab.kind === "loop")) {
          break;
        }
        if (node.label && isBreak) {
          break;
        }
      }
    }
    if (i2 === this.labels.length) {
      this.raise(node.start, "Unsyntactic " + keyword);
    }
    return this.finishNode(node, isBreak ? "BreakStatement" : "ContinueStatement");
  };
  pp$8.parseDebuggerStatement = function(node) {
    this.next();
    this.semicolon();
    return this.finishNode(node, "DebuggerStatement");
  };
  pp$8.parseDoStatement = function(node) {
    this.next();
    this.labels.push(loopLabel);
    node.body = this.parseStatement("do");
    this.labels.pop();
    this.expect(types$1._while);
    node.test = this.parseParenExpression();
    if (this.options.ecmaVersion >= 6) {
      this.eat(types$1.semi);
    } else {
      this.semicolon();
    }
    return this.finishNode(node, "DoWhileStatement");
  };
  pp$8.parseForStatement = function(node) {
    this.next();
    var awaitAt = this.options.ecmaVersion >= 9 && this.canAwait && this.eatContextual("await") ? this.lastTokStart : -1;
    this.labels.push(loopLabel);
    this.enterScope(0);
    this.expect(types$1.parenL);
    if (this.type === types$1.semi) {
      if (awaitAt > -1) {
        this.unexpected(awaitAt);
      }
      return this.parseFor(node, null);
    }
    var isLet = this.isLet();
    if (this.type === types$1._var || this.type === types$1._const || isLet) {
      var init$1 = this.startNode(), kind = isLet ? "let" : this.value;
      this.next();
      this.parseVar(init$1, true, kind);
      this.finishNode(init$1, "VariableDeclaration");
      return this.parseForAfterInit(node, init$1, awaitAt);
    }
    var startsWithLet = this.isContextual("let"), isForOf = false;
    var usingKind = this.isUsing(true) ? "using" : this.isAwaitUsing(true) ? "await using" : null;
    if (usingKind) {
      var init$2 = this.startNode();
      this.next();
      if (usingKind === "await using") {
        if (!this.canAwait) {
          this.raise(this.start, "Await using cannot appear outside of async function");
        }
        this.next();
      }
      this.parseVar(init$2, true, usingKind);
      this.finishNode(init$2, "VariableDeclaration");
      return this.parseForAfterInit(node, init$2, awaitAt);
    }
    var containsEsc = this.containsEsc;
    var refDestructuringErrors = new DestructuringErrors();
    var initPos = this.start;
    var init = awaitAt > -1 ? this.parseExprSubscripts(refDestructuringErrors, "await") : this.parseExpression(true, refDestructuringErrors);
    if (this.type === types$1._in || (isForOf = this.options.ecmaVersion >= 6 && this.isContextual("of"))) {
      if (awaitAt > -1) {
        if (this.type === types$1._in) {
          this.unexpected(awaitAt);
        }
        node.await = true;
      } else if (isForOf && this.options.ecmaVersion >= 8) {
        if (init.start === initPos && !containsEsc && init.type === "Identifier" && init.name === "async") {
          this.unexpected();
        } else if (this.options.ecmaVersion >= 9) {
          node.await = false;
        }
      }
      if (startsWithLet && isForOf) {
        this.raise(init.start, "The left-hand side of a for-of loop may not start with 'let'.");
      }
      this.toAssignable(init, false, refDestructuringErrors);
      this.checkLValPattern(init);
      return this.parseForIn(node, init);
    } else {
      this.checkExpressionErrors(refDestructuringErrors, true);
    }
    if (awaitAt > -1) {
      this.unexpected(awaitAt);
    }
    return this.parseFor(node, init);
  };
  pp$8.parseForAfterInit = function(node, init, awaitAt) {
    if ((this.type === types$1._in || this.options.ecmaVersion >= 6 && this.isContextual("of")) && init.declarations.length === 1) {
      if (this.type === types$1._in) {
        if ((init.kind === "using" || init.kind === "await using") && !init.declarations[0].init) {
          this.raise(this.start, "Using declaration is not allowed in for-in loops");
        }
        if (this.options.ecmaVersion >= 9 && awaitAt > -1) {
          this.unexpected(awaitAt);
        }
      } else if (this.options.ecmaVersion >= 9) {
        node.await = awaitAt > -1;
      }
      return this.parseForIn(node, init);
    }
    if (awaitAt > -1) {
      this.unexpected(awaitAt);
    }
    return this.parseFor(node, init);
  };
  pp$8.parseFunctionStatement = function(node, isAsync, declarationPosition) {
    this.next();
    return this.parseFunction(node, FUNC_STATEMENT | (declarationPosition ? 0 : FUNC_HANGING_STATEMENT), false, isAsync);
  };
  pp$8.parseIfStatement = function(node) {
    this.next();
    node.test = this.parseParenExpression();
    node.consequent = this.parseStatement("if");
    node.alternate = this.eat(types$1._else) ? this.parseStatement("if") : null;
    return this.finishNode(node, "IfStatement");
  };
  pp$8.parseReturnStatement = function(node) {
    if (!this.allowReturn) {
      this.raise(this.start, "'return' outside of function");
    }
    this.next();
    if (this.eat(types$1.semi) || this.insertSemicolon()) {
      node.argument = null;
    } else {
      node.argument = this.parseExpression();
      this.semicolon();
    }
    return this.finishNode(node, "ReturnStatement");
  };
  pp$8.parseSwitchStatement = function(node) {
    this.next();
    node.discriminant = this.parseParenExpression();
    node.cases = [];
    this.expect(types$1.braceL);
    this.labels.push(switchLabel);
    this.enterScope(SCOPE_SWITCH);
    var cur;
    for (var sawDefault = false; this.type !== types$1.braceR; ) {
      if (this.type === types$1._case || this.type === types$1._default) {
        var isCase = this.type === types$1._case;
        if (cur) {
          this.finishNode(cur, "SwitchCase");
        }
        node.cases.push(cur = this.startNode());
        cur.consequent = [];
        this.next();
        if (isCase) {
          cur.test = this.parseExpression();
        } else {
          if (sawDefault) {
            this.raiseRecoverable(this.lastTokStart, "Multiple default clauses");
          }
          sawDefault = true;
          cur.test = null;
        }
        this.expect(types$1.colon);
      } else {
        if (!cur) {
          this.unexpected();
        }
        cur.consequent.push(this.parseStatement(null));
      }
    }
    this.exitScope();
    if (cur) {
      this.finishNode(cur, "SwitchCase");
    }
    this.next();
    this.labels.pop();
    return this.finishNode(node, "SwitchStatement");
  };
  pp$8.parseThrowStatement = function(node) {
    this.next();
    if (lineBreak.test(this.input.slice(this.lastTokEnd, this.start))) {
      this.raise(this.lastTokEnd, "Illegal newline after throw");
    }
    node.argument = this.parseExpression();
    this.semicolon();
    return this.finishNode(node, "ThrowStatement");
  };
  var empty$1 = [];
  pp$8.parseCatchClauseParam = function() {
    var param = this.parseBindingAtom();
    var simple = param.type === "Identifier";
    this.enterScope(simple ? SCOPE_SIMPLE_CATCH : 0);
    this.checkLValPattern(param, simple ? BIND_SIMPLE_CATCH : BIND_LEXICAL);
    this.expect(types$1.parenR);
    return param;
  };
  pp$8.parseTryStatement = function(node) {
    this.next();
    node.block = this.parseBlock();
    node.handler = null;
    if (this.type === types$1._catch) {
      var clause = this.startNode();
      this.next();
      if (this.eat(types$1.parenL)) {
        clause.param = this.parseCatchClauseParam();
      } else {
        if (this.options.ecmaVersion < 10) {
          this.unexpected();
        }
        clause.param = null;
        this.enterScope(0);
      }
      clause.body = this.parseBlock(false);
      this.exitScope();
      node.handler = this.finishNode(clause, "CatchClause");
    }
    node.finalizer = this.eat(types$1._finally) ? this.parseBlock() : null;
    if (!node.handler && !node.finalizer) {
      this.raise(node.start, "Missing catch or finally clause");
    }
    return this.finishNode(node, "TryStatement");
  };
  pp$8.parseVarStatement = function(node, kind, allowMissingInitializer) {
    this.next();
    this.parseVar(node, false, kind, allowMissingInitializer);
    this.semicolon();
    return this.finishNode(node, "VariableDeclaration");
  };
  pp$8.parseWhileStatement = function(node) {
    this.next();
    node.test = this.parseParenExpression();
    this.labels.push(loopLabel);
    node.body = this.parseStatement("while");
    this.labels.pop();
    return this.finishNode(node, "WhileStatement");
  };
  pp$8.parseWithStatement = function(node) {
    if (this.strict) {
      this.raise(this.start, "'with' in strict mode");
    }
    this.next();
    node.object = this.parseParenExpression();
    node.body = this.parseStatement("with");
    return this.finishNode(node, "WithStatement");
  };
  pp$8.parseEmptyStatement = function(node) {
    this.next();
    return this.finishNode(node, "EmptyStatement");
  };
  pp$8.parseLabeledStatement = function(node, maybeName, expr, context) {
    for (var i$1 = 0, list3 = this.labels; i$1 < list3.length; i$1 += 1) {
      var label = list3[i$1];
      if (label.name === maybeName) {
        this.raise(expr.start, "Label '" + maybeName + "' is already declared");
      }
    }
    var kind = this.type.isLoop ? "loop" : this.type === types$1._switch ? "switch" : null;
    for (var i2 = this.labels.length - 1; i2 >= 0; i2--) {
      var label$1 = this.labels[i2];
      if (label$1.statementStart === node.start) {
        label$1.statementStart = this.start;
        label$1.kind = kind;
      } else {
        break;
      }
    }
    this.labels.push({ name: maybeName, kind, statementStart: this.start });
    node.body = this.parseStatement(context ? context.indexOf("label") === -1 ? context + "label" : context : "label");
    this.labels.pop();
    node.label = expr;
    return this.finishNode(node, "LabeledStatement");
  };
  pp$8.parseExpressionStatement = function(node, expr) {
    node.expression = expr;
    this.semicolon();
    return this.finishNode(node, "ExpressionStatement");
  };
  pp$8.parseBlock = function(createNewLexicalScope, node, exitStrict) {
    if (createNewLexicalScope === void 0) createNewLexicalScope = true;
    if (node === void 0) node = this.startNode();
    node.body = [];
    this.expect(types$1.braceL);
    if (createNewLexicalScope) {
      this.enterScope(0);
    }
    while (this.type !== types$1.braceR) {
      var stmt = this.parseStatement(null);
      node.body.push(stmt);
    }
    if (exitStrict) {
      this.strict = false;
    }
    this.next();
    if (createNewLexicalScope) {
      this.exitScope();
    }
    return this.finishNode(node, "BlockStatement");
  };
  pp$8.parseFor = function(node, init) {
    node.init = init;
    this.expect(types$1.semi);
    node.test = this.type === types$1.semi ? null : this.parseExpression();
    this.expect(types$1.semi);
    node.update = this.type === types$1.parenR ? null : this.parseExpression();
    this.expect(types$1.parenR);
    node.body = this.parseStatement("for");
    this.exitScope();
    this.labels.pop();
    return this.finishNode(node, "ForStatement");
  };
  pp$8.parseForIn = function(node, init) {
    var isForIn = this.type === types$1._in;
    this.next();
    if (init.type === "VariableDeclaration" && init.declarations[0].init != null && (!isForIn || this.options.ecmaVersion < 8 || this.strict || init.kind !== "var" || init.declarations[0].id.type !== "Identifier")) {
      this.raise(
        init.start,
        (isForIn ? "for-in" : "for-of") + " loop variable declaration may not have an initializer"
      );
    }
    node.left = init;
    node.right = isForIn ? this.parseExpression() : this.parseMaybeAssign();
    this.expect(types$1.parenR);
    node.body = this.parseStatement("for");
    this.exitScope();
    this.labels.pop();
    return this.finishNode(node, isForIn ? "ForInStatement" : "ForOfStatement");
  };
  pp$8.parseVar = function(node, isFor, kind, allowMissingInitializer) {
    node.declarations = [];
    node.kind = kind;
    for (; ; ) {
      var decl = this.startNode();
      this.parseVarId(decl, kind);
      if (this.eat(types$1.eq)) {
        decl.init = this.parseMaybeAssign(isFor);
      } else if (!allowMissingInitializer && kind === "const" && !(this.type === types$1._in || this.options.ecmaVersion >= 6 && this.isContextual("of"))) {
        this.unexpected();
      } else if (!allowMissingInitializer && (kind === "using" || kind === "await using") && this.options.ecmaVersion >= 17 && this.type !== types$1._in && !this.isContextual("of")) {
        this.raise(this.lastTokEnd, "Missing initializer in " + kind + " declaration");
      } else if (!allowMissingInitializer && decl.id.type !== "Identifier" && !(isFor && (this.type === types$1._in || this.isContextual("of")))) {
        this.raise(this.lastTokEnd, "Complex binding patterns require an initialization value");
      } else {
        decl.init = null;
      }
      node.declarations.push(this.finishNode(decl, "VariableDeclarator"));
      if (!this.eat(types$1.comma)) {
        break;
      }
    }
    return node;
  };
  pp$8.parseVarId = function(decl, kind) {
    decl.id = kind === "using" || kind === "await using" ? this.parseIdent() : this.parseBindingAtom();
    this.checkLValPattern(decl.id, kind === "var" ? BIND_VAR : BIND_LEXICAL, false);
  };
  var FUNC_STATEMENT = 1;
  var FUNC_HANGING_STATEMENT = 2;
  var FUNC_NULLABLE_ID = 4;
  pp$8.parseFunction = function(node, statement, allowExpressionBody, isAsync, forInit) {
    this.initFunction(node);
    if (this.options.ecmaVersion >= 9 || this.options.ecmaVersion >= 6 && !isAsync) {
      if (this.type === types$1.star && statement & FUNC_HANGING_STATEMENT) {
        this.unexpected();
      }
      node.generator = this.eat(types$1.star);
    }
    if (this.options.ecmaVersion >= 8) {
      node.async = !!isAsync;
    }
    if (statement & FUNC_STATEMENT) {
      node.id = statement & FUNC_NULLABLE_ID && this.type !== types$1.name ? null : this.parseIdent();
      if (node.id && !(statement & FUNC_HANGING_STATEMENT)) {
        this.checkLValSimple(node.id, this.strict || node.generator || node.async ? this.treatFunctionsAsVar ? BIND_VAR : BIND_LEXICAL : BIND_FUNCTION);
      }
    }
    var oldYieldPos = this.yieldPos, oldAwaitPos = this.awaitPos, oldAwaitIdentPos = this.awaitIdentPos;
    this.yieldPos = 0;
    this.awaitPos = 0;
    this.awaitIdentPos = 0;
    this.enterScope(functionFlags(node.async, node.generator));
    if (!(statement & FUNC_STATEMENT)) {
      node.id = this.type === types$1.name ? this.parseIdent() : null;
    }
    this.parseFunctionParams(node);
    this.parseFunctionBody(node, allowExpressionBody, false, forInit);
    this.yieldPos = oldYieldPos;
    this.awaitPos = oldAwaitPos;
    this.awaitIdentPos = oldAwaitIdentPos;
    return this.finishNode(node, statement & FUNC_STATEMENT ? "FunctionDeclaration" : "FunctionExpression");
  };
  pp$8.parseFunctionParams = function(node) {
    this.expect(types$1.parenL);
    node.params = this.parseBindingList(types$1.parenR, false, this.options.ecmaVersion >= 8);
    this.checkYieldAwaitInDefaultParams();
  };
  pp$8.parseClass = function(node, isStatement) {
    this.next();
    var oldStrict = this.strict;
    this.strict = true;
    this.parseClassId(node, isStatement);
    this.parseClassSuper(node);
    var privateNameMap = this.enterClassBody();
    var classBody = this.startNode();
    var hadConstructor = false;
    classBody.body = [];
    this.expect(types$1.braceL);
    while (this.type !== types$1.braceR) {
      var element = this.parseClassElement(node.superClass !== null);
      if (element) {
        classBody.body.push(element);
        if (element.type === "MethodDefinition" && element.kind === "constructor") {
          if (hadConstructor) {
            this.raiseRecoverable(element.start, "Duplicate constructor in the same class");
          }
          hadConstructor = true;
        } else if (element.key && element.key.type === "PrivateIdentifier" && isPrivateNameConflicted(privateNameMap, element)) {
          this.raiseRecoverable(element.key.start, "Identifier '#" + element.key.name + "' has already been declared");
        }
      }
    }
    this.strict = oldStrict;
    this.next();
    node.body = this.finishNode(classBody, "ClassBody");
    this.exitClassBody();
    return this.finishNode(node, isStatement ? "ClassDeclaration" : "ClassExpression");
  };
  pp$8.parseClassElement = function(constructorAllowsSuper) {
    if (this.eat(types$1.semi)) {
      return null;
    }
    var ecmaVersion2 = this.options.ecmaVersion;
    var node = this.startNode();
    var keyName = "";
    var isGenerator = false;
    var isAsync = false;
    var kind = "method";
    var isStatic = false;
    if (this.eatContextual("static")) {
      if (ecmaVersion2 >= 13 && this.eat(types$1.braceL)) {
        this.parseClassStaticBlock(node);
        return node;
      }
      if (this.isClassElementNameStart() || this.type === types$1.star) {
        isStatic = true;
      } else {
        keyName = "static";
      }
    }
    node.static = isStatic;
    if (!keyName && ecmaVersion2 >= 8 && this.eatContextual("async")) {
      if ((this.isClassElementNameStart() || this.type === types$1.star) && !this.canInsertSemicolon()) {
        isAsync = true;
      } else {
        keyName = "async";
      }
    }
    if (!keyName && (ecmaVersion2 >= 9 || !isAsync) && this.eat(types$1.star)) {
      isGenerator = true;
    }
    if (!keyName && !isAsync && !isGenerator) {
      var lastValue = this.value;
      if (this.eatContextual("get") || this.eatContextual("set")) {
        if (this.isClassElementNameStart()) {
          kind = lastValue;
        } else {
          keyName = lastValue;
        }
      }
    }
    if (keyName) {
      node.computed = false;
      node.key = this.startNodeAt(this.lastTokStart, this.lastTokStartLoc);
      node.key.name = keyName;
      this.finishNode(node.key, "Identifier");
    } else {
      this.parseClassElementName(node);
    }
    if (ecmaVersion2 < 13 || this.type === types$1.parenL || kind !== "method" || isGenerator || isAsync) {
      var isConstructor = !node.static && checkKeyName(node, "constructor");
      var allowsDirectSuper = isConstructor && constructorAllowsSuper;
      if (isConstructor && kind !== "method") {
        this.raise(node.key.start, "Constructor can't have get/set modifier");
      }
      node.kind = isConstructor ? "constructor" : kind;
      this.parseClassMethod(node, isGenerator, isAsync, allowsDirectSuper);
    } else {
      this.parseClassField(node);
    }
    return node;
  };
  pp$8.isClassElementNameStart = function() {
    return this.type === types$1.name || this.type === types$1.privateId || this.type === types$1.num || this.type === types$1.string || this.type === types$1.bracketL || this.type.keyword;
  };
  pp$8.parseClassElementName = function(element) {
    if (this.type === types$1.privateId) {
      if (this.value === "constructor") {
        this.raise(this.start, "Classes can't have an element named '#constructor'");
      }
      element.computed = false;
      element.key = this.parsePrivateIdent();
    } else {
      this.parsePropertyName(element);
    }
  };
  pp$8.parseClassMethod = function(method, isGenerator, isAsync, allowsDirectSuper) {
    var key = method.key;
    if (method.kind === "constructor") {
      if (isGenerator) {
        this.raise(key.start, "Constructor can't be a generator");
      }
      if (isAsync) {
        this.raise(key.start, "Constructor can't be an async method");
      }
    } else if (method.static && checkKeyName(method, "prototype")) {
      this.raise(key.start, "Classes may not have a static property named prototype");
    }
    var value = method.value = this.parseMethod(isGenerator, isAsync, allowsDirectSuper);
    if (method.kind === "get" && value.params.length !== 0) {
      this.raiseRecoverable(value.start, "getter should have no params");
    }
    if (method.kind === "set" && value.params.length !== 1) {
      this.raiseRecoverable(value.start, "setter should have exactly one param");
    }
    if (method.kind === "set" && value.params[0].type === "RestElement") {
      this.raiseRecoverable(value.params[0].start, "Setter cannot use rest params");
    }
    return this.finishNode(method, "MethodDefinition");
  };
  pp$8.parseClassField = function(field) {
    if (checkKeyName(field, "constructor")) {
      this.raise(field.key.start, "Classes can't have a field named 'constructor'");
    } else if (field.static && checkKeyName(field, "prototype")) {
      this.raise(field.key.start, "Classes can't have a static field named 'prototype'");
    }
    if (this.eat(types$1.eq)) {
      this.enterScope(SCOPE_CLASS_FIELD_INIT | SCOPE_SUPER);
      field.value = this.parseMaybeAssign();
      this.exitScope();
    } else {
      field.value = null;
    }
    this.semicolon();
    return this.finishNode(field, "PropertyDefinition");
  };
  pp$8.parseClassStaticBlock = function(node) {
    node.body = [];
    var oldLabels = this.labels;
    this.labels = [];
    this.enterScope(SCOPE_CLASS_STATIC_BLOCK | SCOPE_SUPER);
    while (this.type !== types$1.braceR) {
      var stmt = this.parseStatement(null);
      node.body.push(stmt);
    }
    this.next();
    this.exitScope();
    this.labels = oldLabels;
    return this.finishNode(node, "StaticBlock");
  };
  pp$8.parseClassId = function(node, isStatement) {
    if (this.type === types$1.name) {
      node.id = this.parseIdent();
      if (isStatement) {
        this.checkLValSimple(node.id, BIND_LEXICAL, false);
      }
    } else {
      if (isStatement === true) {
        this.unexpected();
      }
      node.id = null;
    }
  };
  pp$8.parseClassSuper = function(node) {
    node.superClass = this.eat(types$1._extends) ? this.parseExprSubscripts(null, false) : null;
  };
  pp$8.enterClassBody = function() {
    var element = { declared: /* @__PURE__ */ Object.create(null), used: [] };
    this.privateNameStack.push(element);
    return element.declared;
  };
  pp$8.exitClassBody = function() {
    var ref2 = this.privateNameStack.pop();
    var declared = ref2.declared;
    var used = ref2.used;
    if (!this.options.checkPrivateFields) {
      return;
    }
    var len = this.privateNameStack.length;
    var parent = len === 0 ? null : this.privateNameStack[len - 1];
    for (var i2 = 0; i2 < used.length; ++i2) {
      var id = used[i2];
      if (!hasOwn(declared, id.name)) {
        if (parent) {
          parent.used.push(id);
        } else {
          this.raiseRecoverable(id.start, "Private field '#" + id.name + "' must be declared in an enclosing class");
        }
      }
    }
  };
  function isPrivateNameConflicted(privateNameMap, element) {
    var name = element.key.name;
    var curr = privateNameMap[name];
    var next = "true";
    if (element.type === "MethodDefinition" && (element.kind === "get" || element.kind === "set")) {
      next = (element.static ? "s" : "i") + element.kind;
    }
    if (curr === "iget" && next === "iset" || curr === "iset" && next === "iget" || curr === "sget" && next === "sset" || curr === "sset" && next === "sget") {
      privateNameMap[name] = "true";
      return false;
    } else if (!curr) {
      privateNameMap[name] = next;
      return false;
    } else {
      return true;
    }
  }
  function checkKeyName(node, name) {
    var computed = node.computed;
    var key = node.key;
    return !computed && (key.type === "Identifier" && key.name === name || key.type === "Literal" && key.value === name);
  }
  pp$8.parseExportAllDeclaration = function(node, exports$1) {
    if (this.options.ecmaVersion >= 11) {
      if (this.eatContextual("as")) {
        node.exported = this.parseModuleExportName();
        this.checkExport(exports$1, node.exported, this.lastTokStart);
      } else {
        node.exported = null;
      }
    }
    this.expectContextual("from");
    if (this.type !== types$1.string) {
      this.unexpected();
    }
    node.source = this.parseExprAtom();
    if (this.options.ecmaVersion >= 16) {
      node.attributes = this.parseWithClause();
    }
    this.semicolon();
    return this.finishNode(node, "ExportAllDeclaration");
  };
  pp$8.parseExport = function(node, exports$1) {
    this.next();
    if (this.eat(types$1.star)) {
      return this.parseExportAllDeclaration(node, exports$1);
    }
    if (this.eat(types$1._default)) {
      this.checkExport(exports$1, "default", this.lastTokStart);
      node.declaration = this.parseExportDefaultDeclaration();
      return this.finishNode(node, "ExportDefaultDeclaration");
    }
    if (this.shouldParseExportStatement()) {
      node.declaration = this.parseExportDeclaration(node);
      if (node.declaration.type === "VariableDeclaration") {
        this.checkVariableExport(exports$1, node.declaration.declarations);
      } else {
        this.checkExport(exports$1, node.declaration.id, node.declaration.id.start);
      }
      node.specifiers = [];
      node.source = null;
      if (this.options.ecmaVersion >= 16) {
        node.attributes = [];
      }
    } else {
      node.declaration = null;
      node.specifiers = this.parseExportSpecifiers(exports$1);
      if (this.eatContextual("from")) {
        if (this.type !== types$1.string) {
          this.unexpected();
        }
        node.source = this.parseExprAtom();
        if (this.options.ecmaVersion >= 16) {
          node.attributes = this.parseWithClause();
        }
      } else {
        for (var i2 = 0, list3 = node.specifiers; i2 < list3.length; i2 += 1) {
          var spec = list3[i2];
          this.checkUnreserved(spec.local);
          this.checkLocalExport(spec.local);
          if (spec.local.type === "Literal") {
            this.raise(spec.local.start, "A string literal cannot be used as an exported binding without `from`.");
          }
        }
        node.source = null;
        if (this.options.ecmaVersion >= 16) {
          node.attributes = [];
        }
      }
      this.semicolon();
    }
    return this.finishNode(node, "ExportNamedDeclaration");
  };
  pp$8.parseExportDeclaration = function(node) {
    return this.parseStatement(null);
  };
  pp$8.parseExportDefaultDeclaration = function() {
    var isAsync;
    if (this.type === types$1._function || (isAsync = this.isAsyncFunction())) {
      var fNode = this.startNode();
      this.next();
      if (isAsync) {
        this.next();
      }
      return this.parseFunction(fNode, FUNC_STATEMENT | FUNC_NULLABLE_ID, false, isAsync);
    } else if (this.type === types$1._class) {
      var cNode = this.startNode();
      return this.parseClass(cNode, "nullableID");
    } else {
      var declaration = this.parseMaybeAssign();
      this.semicolon();
      return declaration;
    }
  };
  pp$8.checkExport = function(exports$1, name, pos) {
    if (!exports$1) {
      return;
    }
    if (typeof name !== "string") {
      name = name.type === "Identifier" ? name.name : name.value;
    }
    if (hasOwn(exports$1, name)) {
      this.raiseRecoverable(pos, "Duplicate export '" + name + "'");
    }
    exports$1[name] = true;
  };
  pp$8.checkPatternExport = function(exports$1, pat) {
    var type = pat.type;
    if (type === "Identifier") {
      this.checkExport(exports$1, pat, pat.start);
    } else if (type === "ObjectPattern") {
      for (var i2 = 0, list3 = pat.properties; i2 < list3.length; i2 += 1) {
        var prop = list3[i2];
        this.checkPatternExport(exports$1, prop);
      }
    } else if (type === "ArrayPattern") {
      for (var i$1 = 0, list$1 = pat.elements; i$1 < list$1.length; i$1 += 1) {
        var elt = list$1[i$1];
        if (elt) {
          this.checkPatternExport(exports$1, elt);
        }
      }
    } else if (type === "Property") {
      this.checkPatternExport(exports$1, pat.value);
    } else if (type === "AssignmentPattern") {
      this.checkPatternExport(exports$1, pat.left);
    } else if (type === "RestElement") {
      this.checkPatternExport(exports$1, pat.argument);
    }
  };
  pp$8.checkVariableExport = function(exports$1, decls) {
    if (!exports$1) {
      return;
    }
    for (var i2 = 0, list3 = decls; i2 < list3.length; i2 += 1) {
      var decl = list3[i2];
      this.checkPatternExport(exports$1, decl.id);
    }
  };
  pp$8.shouldParseExportStatement = function() {
    return this.type.keyword === "var" || this.type.keyword === "const" || this.type.keyword === "class" || this.type.keyword === "function" || this.isLet() || this.isAsyncFunction();
  };
  pp$8.parseExportSpecifier = function(exports$1) {
    var node = this.startNode();
    node.local = this.parseModuleExportName();
    node.exported = this.eatContextual("as") ? this.parseModuleExportName() : node.local;
    this.checkExport(
      exports$1,
      node.exported,
      node.exported.start
    );
    return this.finishNode(node, "ExportSpecifier");
  };
  pp$8.parseExportSpecifiers = function(exports$1) {
    var nodes = [], first = true;
    this.expect(types$1.braceL);
    while (!this.eat(types$1.braceR)) {
      if (!first) {
        this.expect(types$1.comma);
        if (this.afterTrailingComma(types$1.braceR)) {
          break;
        }
      } else {
        first = false;
      }
      nodes.push(this.parseExportSpecifier(exports$1));
    }
    return nodes;
  };
  pp$8.parseImport = function(node) {
    this.next();
    if (this.type === types$1.string) {
      node.specifiers = empty$1;
      node.source = this.parseExprAtom();
    } else {
      node.specifiers = this.parseImportSpecifiers();
      this.expectContextual("from");
      node.source = this.type === types$1.string ? this.parseExprAtom() : this.unexpected();
    }
    if (this.options.ecmaVersion >= 16) {
      node.attributes = this.parseWithClause();
    }
    this.semicolon();
    return this.finishNode(node, "ImportDeclaration");
  };
  pp$8.parseImportSpecifier = function() {
    var node = this.startNode();
    node.imported = this.parseModuleExportName();
    if (this.eatContextual("as")) {
      node.local = this.parseIdent();
    } else {
      this.checkUnreserved(node.imported);
      node.local = node.imported;
    }
    this.checkLValSimple(node.local, BIND_LEXICAL);
    return this.finishNode(node, "ImportSpecifier");
  };
  pp$8.parseImportDefaultSpecifier = function() {
    var node = this.startNode();
    node.local = this.parseIdent();
    this.checkLValSimple(node.local, BIND_LEXICAL);
    return this.finishNode(node, "ImportDefaultSpecifier");
  };
  pp$8.parseImportNamespaceSpecifier = function() {
    var node = this.startNode();
    this.next();
    this.expectContextual("as");
    node.local = this.parseIdent();
    this.checkLValSimple(node.local, BIND_LEXICAL);
    return this.finishNode(node, "ImportNamespaceSpecifier");
  };
  pp$8.parseImportSpecifiers = function() {
    var nodes = [], first = true;
    if (this.type === types$1.name) {
      nodes.push(this.parseImportDefaultSpecifier());
      if (!this.eat(types$1.comma)) {
        return nodes;
      }
    }
    if (this.type === types$1.star) {
      nodes.push(this.parseImportNamespaceSpecifier());
      return nodes;
    }
    this.expect(types$1.braceL);
    while (!this.eat(types$1.braceR)) {
      if (!first) {
        this.expect(types$1.comma);
        if (this.afterTrailingComma(types$1.braceR)) {
          break;
        }
      } else {
        first = false;
      }
      nodes.push(this.parseImportSpecifier());
    }
    return nodes;
  };
  pp$8.parseWithClause = function() {
    var nodes = [];
    if (!this.eat(types$1._with)) {
      return nodes;
    }
    this.expect(types$1.braceL);
    var attributeKeys = {};
    var first = true;
    while (!this.eat(types$1.braceR)) {
      if (!first) {
        this.expect(types$1.comma);
        if (this.afterTrailingComma(types$1.braceR)) {
          break;
        }
      } else {
        first = false;
      }
      var attr = this.parseImportAttribute();
      var keyName = attr.key.type === "Identifier" ? attr.key.name : attr.key.value;
      if (hasOwn(attributeKeys, keyName)) {
        this.raiseRecoverable(attr.key.start, "Duplicate attribute key '" + keyName + "'");
      }
      attributeKeys[keyName] = true;
      nodes.push(attr);
    }
    return nodes;
  };
  pp$8.parseImportAttribute = function() {
    var node = this.startNode();
    node.key = this.type === types$1.string ? this.parseExprAtom() : this.parseIdent(this.options.allowReserved !== "never");
    this.expect(types$1.colon);
    if (this.type !== types$1.string) {
      this.unexpected();
    }
    node.value = this.parseExprAtom();
    return this.finishNode(node, "ImportAttribute");
  };
  pp$8.parseModuleExportName = function() {
    if (this.options.ecmaVersion >= 13 && this.type === types$1.string) {
      var stringLiteral = this.parseLiteral(this.value);
      if (loneSurrogate.test(stringLiteral.value)) {
        this.raise(stringLiteral.start, "An export name cannot include a lone surrogate.");
      }
      return stringLiteral;
    }
    return this.parseIdent(true);
  };
  pp$8.adaptDirectivePrologue = function(statements) {
    for (var i2 = 0; i2 < statements.length && this.isDirectiveCandidate(statements[i2]); ++i2) {
      statements[i2].directive = statements[i2].expression.raw.slice(1, -1);
    }
  };
  pp$8.isDirectiveCandidate = function(statement) {
    return this.options.ecmaVersion >= 5 && statement.type === "ExpressionStatement" && statement.expression.type === "Literal" && typeof statement.expression.value === "string" && // Reject parenthesized strings.
    (this.input[statement.start] === '"' || this.input[statement.start] === "'");
  };
  var pp$7 = Parser.prototype;
  pp$7.toAssignable = function(node, isBinding, refDestructuringErrors) {
    if (this.options.ecmaVersion >= 6 && node) {
      switch (node.type) {
        case "Identifier":
          if (this.inAsync && node.name === "await") {
            this.raise(node.start, "Cannot use 'await' as identifier inside an async function");
          }
          break;
        case "ObjectPattern":
        case "ArrayPattern":
        case "AssignmentPattern":
        case "RestElement":
          break;
        case "ObjectExpression":
          node.type = "ObjectPattern";
          if (refDestructuringErrors) {
            this.checkPatternErrors(refDestructuringErrors, true);
          }
          for (var i2 = 0, list3 = node.properties; i2 < list3.length; i2 += 1) {
            var prop = list3[i2];
            this.toAssignable(prop, isBinding);
            if (prop.type === "RestElement" && (prop.argument.type === "ArrayPattern" || prop.argument.type === "ObjectPattern")) {
              this.raise(prop.argument.start, "Unexpected token");
            }
          }
          break;
        case "Property":
          if (node.kind !== "init") {
            this.raise(node.key.start, "Object pattern can't contain getter or setter");
          }
          this.toAssignable(node.value, isBinding);
          break;
        case "ArrayExpression":
          node.type = "ArrayPattern";
          if (refDestructuringErrors) {
            this.checkPatternErrors(refDestructuringErrors, true);
          }
          this.toAssignableList(node.elements, isBinding);
          break;
        case "SpreadElement":
          node.type = "RestElement";
          this.toAssignable(node.argument, isBinding);
          if (node.argument.type === "AssignmentPattern") {
            this.raise(node.argument.start, "Rest elements cannot have a default value");
          }
          break;
        case "AssignmentExpression":
          if (node.operator !== "=") {
            this.raise(node.left.end, "Only '=' operator can be used for specifying default value.");
          }
          node.type = "AssignmentPattern";
          delete node.operator;
          this.toAssignable(node.left, isBinding);
          break;
        case "ParenthesizedExpression":
          this.toAssignable(node.expression, isBinding, refDestructuringErrors);
          break;
        case "ChainExpression":
          this.raiseRecoverable(node.start, "Optional chaining cannot appear in left-hand side");
          break;
        case "MemberExpression":
          if (!isBinding) {
            break;
          }
        default:
          this.raise(node.start, "Assigning to rvalue");
      }
    } else if (refDestructuringErrors) {
      this.checkPatternErrors(refDestructuringErrors, true);
    }
    return node;
  };
  pp$7.toAssignableList = function(exprList, isBinding) {
    var end = exprList.length;
    for (var i2 = 0; i2 < end; i2++) {
      var elt = exprList[i2];
      if (elt) {
        this.toAssignable(elt, isBinding);
      }
    }
    if (end) {
      var last = exprList[end - 1];
      if (this.options.ecmaVersion === 6 && isBinding && last && last.type === "RestElement" && last.argument.type !== "Identifier") {
        this.unexpected(last.argument.start);
      }
    }
    return exprList;
  };
  pp$7.parseSpread = function(refDestructuringErrors) {
    var node = this.startNode();
    this.next();
    node.argument = this.parseMaybeAssign(false, refDestructuringErrors);
    return this.finishNode(node, "SpreadElement");
  };
  pp$7.parseRestBinding = function() {
    var node = this.startNode();
    this.next();
    if (this.options.ecmaVersion === 6 && this.type !== types$1.name) {
      this.unexpected();
    }
    node.argument = this.parseBindingAtom();
    return this.finishNode(node, "RestElement");
  };
  pp$7.parseBindingAtom = function() {
    if (this.options.ecmaVersion >= 6) {
      switch (this.type) {
        case types$1.bracketL:
          var node = this.startNode();
          this.next();
          node.elements = this.parseBindingList(types$1.bracketR, true, true);
          return this.finishNode(node, "ArrayPattern");
        case types$1.braceL:
          return this.parseObj(true);
      }
    }
    return this.parseIdent();
  };
  pp$7.parseBindingList = function(close, allowEmpty, allowTrailingComma, allowModifiers) {
    var elts = [], first = true;
    while (!this.eat(close)) {
      if (first) {
        first = false;
      } else {
        this.expect(types$1.comma);
      }
      if (allowEmpty && this.type === types$1.comma) {
        elts.push(null);
      } else if (allowTrailingComma && this.afterTrailingComma(close)) {
        break;
      } else if (this.type === types$1.ellipsis) {
        var rest = this.parseRestBinding();
        this.parseBindingListItem(rest);
        elts.push(rest);
        if (this.type === types$1.comma) {
          this.raiseRecoverable(this.start, "Comma is not permitted after the rest element");
        }
        this.expect(close);
        break;
      } else {
        elts.push(this.parseAssignableListItem(allowModifiers));
      }
    }
    return elts;
  };
  pp$7.parseAssignableListItem = function(allowModifiers) {
    var elem = this.parseMaybeDefault(this.start, this.startLoc);
    this.parseBindingListItem(elem);
    return elem;
  };
  pp$7.parseBindingListItem = function(param) {
    return param;
  };
  pp$7.parseMaybeDefault = function(startPos, startLoc, left) {
    left = left || this.parseBindingAtom();
    if (this.options.ecmaVersion < 6 || !this.eat(types$1.eq)) {
      return left;
    }
    var node = this.startNodeAt(startPos, startLoc);
    node.left = left;
    node.right = this.parseMaybeAssign();
    return this.finishNode(node, "AssignmentPattern");
  };
  pp$7.checkLValSimple = function(expr, bindingType, checkClashes) {
    if (bindingType === void 0) bindingType = BIND_NONE;
    var isBind = bindingType !== BIND_NONE;
    switch (expr.type) {
      case "Identifier":
        if (this.strict && this.reservedWordsStrictBind.test(expr.name)) {
          this.raiseRecoverable(expr.start, (isBind ? "Binding " : "Assigning to ") + expr.name + " in strict mode");
        }
        if (isBind) {
          if (bindingType === BIND_LEXICAL && expr.name === "let") {
            this.raiseRecoverable(expr.start, "let is disallowed as a lexically bound name");
          }
          if (checkClashes) {
            if (hasOwn(checkClashes, expr.name)) {
              this.raiseRecoverable(expr.start, "Argument name clash");
            }
            checkClashes[expr.name] = true;
          }
          if (bindingType !== BIND_OUTSIDE) {
            this.declareName(expr.name, bindingType, expr.start);
          }
        }
        break;
      case "ChainExpression":
        this.raiseRecoverable(expr.start, "Optional chaining cannot appear in left-hand side");
        break;
      case "MemberExpression":
        if (isBind) {
          this.raiseRecoverable(expr.start, "Binding member expression");
        }
        break;
      case "ParenthesizedExpression":
        if (isBind) {
          this.raiseRecoverable(expr.start, "Binding parenthesized expression");
        }
        return this.checkLValSimple(expr.expression, bindingType, checkClashes);
      default:
        this.raise(expr.start, (isBind ? "Binding" : "Assigning to") + " rvalue");
    }
  };
  pp$7.checkLValPattern = function(expr, bindingType, checkClashes) {
    if (bindingType === void 0) bindingType = BIND_NONE;
    switch (expr.type) {
      case "ObjectPattern":
        for (var i2 = 0, list3 = expr.properties; i2 < list3.length; i2 += 1) {
          var prop = list3[i2];
          this.checkLValInnerPattern(prop, bindingType, checkClashes);
        }
        break;
      case "ArrayPattern":
        for (var i$1 = 0, list$1 = expr.elements; i$1 < list$1.length; i$1 += 1) {
          var elem = list$1[i$1];
          if (elem) {
            this.checkLValInnerPattern(elem, bindingType, checkClashes);
          }
        }
        break;
      default:
        this.checkLValSimple(expr, bindingType, checkClashes);
    }
  };
  pp$7.checkLValInnerPattern = function(expr, bindingType, checkClashes) {
    if (bindingType === void 0) bindingType = BIND_NONE;
    switch (expr.type) {
      case "Property":
        this.checkLValInnerPattern(expr.value, bindingType, checkClashes);
        break;
      case "AssignmentPattern":
        this.checkLValPattern(expr.left, bindingType, checkClashes);
        break;
      case "RestElement":
        this.checkLValPattern(expr.argument, bindingType, checkClashes);
        break;
      default:
        this.checkLValPattern(expr, bindingType, checkClashes);
    }
  };
  var TokContext = function TokContext2(token, isExpr, preserveSpace, override, generator) {
    this.token = token;
    this.isExpr = !!isExpr;
    this.preserveSpace = !!preserveSpace;
    this.override = override;
    this.generator = !!generator;
  };
  var types = {
    b_stat: new TokContext("{", false),
    b_expr: new TokContext("{", true),
    b_tmpl: new TokContext("${", false),
    p_stat: new TokContext("(", false),
    p_expr: new TokContext("(", true),
    q_tmpl: new TokContext("`", true, true, function(p) {
      return p.tryReadTemplateToken();
    }),
    f_stat: new TokContext("function", false),
    f_expr: new TokContext("function", true),
    f_expr_gen: new TokContext("function", true, false, null, true),
    f_gen: new TokContext("function", false, false, null, true)
  };
  var pp$6 = Parser.prototype;
  pp$6.initialContext = function() {
    return [types.b_stat];
  };
  pp$6.curContext = function() {
    return this.context[this.context.length - 1];
  };
  pp$6.braceIsBlock = function(prevType) {
    var parent = this.curContext();
    if (parent === types.f_expr || parent === types.f_stat) {
      return true;
    }
    if (prevType === types$1.colon && (parent === types.b_stat || parent === types.b_expr)) {
      return !parent.isExpr;
    }
    if (prevType === types$1._return || prevType === types$1.name && this.exprAllowed) {
      return lineBreak.test(this.input.slice(this.lastTokEnd, this.start));
    }
    if (prevType === types$1._else || prevType === types$1.semi || prevType === types$1.eof || prevType === types$1.parenR || prevType === types$1.arrow) {
      return true;
    }
    if (prevType === types$1.braceL) {
      return parent === types.b_stat;
    }
    if (prevType === types$1._var || prevType === types$1._const || prevType === types$1.name) {
      return false;
    }
    return !this.exprAllowed;
  };
  pp$6.inGeneratorContext = function() {
    for (var i2 = this.context.length - 1; i2 >= 1; i2--) {
      var context = this.context[i2];
      if (context.token === "function") {
        return context.generator;
      }
    }
    return false;
  };
  pp$6.updateContext = function(prevType) {
    var update, type = this.type;
    if (type.keyword && prevType === types$1.dot) {
      this.exprAllowed = false;
    } else if (update = type.updateContext) {
      update.call(this, prevType);
    } else {
      this.exprAllowed = type.beforeExpr;
    }
  };
  pp$6.overrideContext = function(tokenCtx) {
    if (this.curContext() !== tokenCtx) {
      this.context[this.context.length - 1] = tokenCtx;
    }
  };
  types$1.parenR.updateContext = types$1.braceR.updateContext = function() {
    if (this.context.length === 1) {
      this.exprAllowed = true;
      return;
    }
    var out = this.context.pop();
    if (out === types.b_stat && this.curContext().token === "function") {
      out = this.context.pop();
    }
    this.exprAllowed = !out.isExpr;
  };
  types$1.braceL.updateContext = function(prevType) {
    this.context.push(this.braceIsBlock(prevType) ? types.b_stat : types.b_expr);
    this.exprAllowed = true;
  };
  types$1.dollarBraceL.updateContext = function() {
    this.context.push(types.b_tmpl);
    this.exprAllowed = true;
  };
  types$1.parenL.updateContext = function(prevType) {
    var statementParens = prevType === types$1._if || prevType === types$1._for || prevType === types$1._with || prevType === types$1._while;
    this.context.push(statementParens ? types.p_stat : types.p_expr);
    this.exprAllowed = true;
  };
  types$1.incDec.updateContext = function() {
  };
  types$1._function.updateContext = types$1._class.updateContext = function(prevType) {
    if (prevType.beforeExpr && prevType !== types$1._else && !(prevType === types$1.semi && this.curContext() !== types.p_stat) && !(prevType === types$1._return && lineBreak.test(this.input.slice(this.lastTokEnd, this.start))) && !((prevType === types$1.colon || prevType === types$1.braceL) && this.curContext() === types.b_stat)) {
      this.context.push(types.f_expr);
    } else {
      this.context.push(types.f_stat);
    }
    this.exprAllowed = false;
  };
  types$1.colon.updateContext = function() {
    if (this.curContext().token === "function") {
      this.context.pop();
    }
    this.exprAllowed = true;
  };
  types$1.backQuote.updateContext = function() {
    if (this.curContext() === types.q_tmpl) {
      this.context.pop();
    } else {
      this.context.push(types.q_tmpl);
    }
    this.exprAllowed = false;
  };
  types$1.star.updateContext = function(prevType) {
    if (prevType === types$1._function) {
      var index = this.context.length - 1;
      if (this.context[index] === types.f_expr) {
        this.context[index] = types.f_expr_gen;
      } else {
        this.context[index] = types.f_gen;
      }
    }
    this.exprAllowed = true;
  };
  types$1.name.updateContext = function(prevType) {
    var allowed = false;
    if (this.options.ecmaVersion >= 6 && prevType !== types$1.dot) {
      if (this.value === "of" && !this.exprAllowed || this.value === "yield" && this.inGeneratorContext()) {
        allowed = true;
      }
    }
    this.exprAllowed = allowed;
  };
  var pp$5 = Parser.prototype;
  pp$5.checkPropClash = function(prop, propHash, refDestructuringErrors) {
    if (this.options.ecmaVersion >= 9 && prop.type === "SpreadElement") {
      return;
    }
    if (this.options.ecmaVersion >= 6 && (prop.computed || prop.method || prop.shorthand)) {
      return;
    }
    var key = prop.key;
    var name;
    switch (key.type) {
      case "Identifier":
        name = key.name;
        break;
      case "Literal":
        name = String(key.value);
        break;
      default:
        return;
    }
    var kind = prop.kind;
    if (this.options.ecmaVersion >= 6) {
      if (name === "__proto__" && kind === "init") {
        if (propHash.proto) {
          if (refDestructuringErrors) {
            if (refDestructuringErrors.doubleProto < 0) {
              refDestructuringErrors.doubleProto = key.start;
            }
          } else {
            this.raiseRecoverable(key.start, "Redefinition of __proto__ property");
          }
        }
        propHash.proto = true;
      }
      return;
    }
    name = "$" + name;
    var other = propHash[name];
    if (other) {
      var redefinition;
      if (kind === "init") {
        redefinition = this.strict && other.init || other.get || other.set;
      } else {
        redefinition = other.init || other[kind];
      }
      if (redefinition) {
        this.raiseRecoverable(key.start, "Redefinition of property");
      }
    } else {
      other = propHash[name] = {
        init: false,
        get: false,
        set: false
      };
    }
    other[kind] = true;
  };
  pp$5.parseExpression = function(forInit, refDestructuringErrors) {
    var this$1$1 = this;
    return this.catchStackOverflow(function() {
      var startPos = this$1$1.start, startLoc = this$1$1.startLoc;
      var expr = this$1$1.parseMaybeAssign(forInit, refDestructuringErrors);
      if (this$1$1.type === types$1.comma) {
        var node = this$1$1.startNodeAt(startPos, startLoc);
        node.expressions = [expr];
        while (this$1$1.eat(types$1.comma)) {
          node.expressions.push(this$1$1.parseMaybeAssign(forInit, refDestructuringErrors));
        }
        return this$1$1.finishNode(node, "SequenceExpression");
      }
      return expr;
    });
  };
  pp$5.parseMaybeAssign = function(forInit, refDestructuringErrors, afterLeftParse) {
    if (this.isContextual("yield")) {
      if (this.inGenerator) {
        return this.parseYield(forInit);
      } else {
        this.exprAllowed = false;
      }
    }
    var ownDestructuringErrors = false, oldParenAssign = -1, oldTrailingComma = -1, oldDoubleProto = -1;
    if (refDestructuringErrors) {
      oldParenAssign = refDestructuringErrors.parenthesizedAssign;
      oldTrailingComma = refDestructuringErrors.trailingComma;
      oldDoubleProto = refDestructuringErrors.doubleProto;
      refDestructuringErrors.parenthesizedAssign = refDestructuringErrors.trailingComma = -1;
    } else {
      refDestructuringErrors = new DestructuringErrors();
      ownDestructuringErrors = true;
    }
    var startPos = this.start, startLoc = this.startLoc;
    if (this.type === types$1.parenL || this.type === types$1.name) {
      this.potentialArrowAt = this.start;
      this.potentialArrowInForAwait = forInit === "await";
    }
    var left = this.parseMaybeConditional(forInit, refDestructuringErrors);
    if (afterLeftParse) {
      left = afterLeftParse.call(this, left, startPos, startLoc);
    }
    if (this.type.isAssign) {
      var node = this.startNodeAt(startPos, startLoc);
      node.operator = this.value;
      if (this.type === types$1.eq) {
        left = this.toAssignable(left, false, refDestructuringErrors);
      }
      if (!ownDestructuringErrors) {
        refDestructuringErrors.parenthesizedAssign = refDestructuringErrors.trailingComma = -1;
        if (refDestructuringErrors.shorthandAssign >= left.start) {
          refDestructuringErrors.shorthandAssign = -1;
        }
        if (refDestructuringErrors.doubleProto >= left.start) {
          refDestructuringErrors.doubleProto = -1;
        }
      }
      if (this.type === types$1.eq) {
        this.checkLValPattern(left);
      } else {
        this.checkLValSimple(left);
      }
      node.left = left;
      this.next();
      node.right = this.parseMaybeAssign(forInit);
      if (oldDoubleProto > -1) {
        refDestructuringErrors.doubleProto = oldDoubleProto;
      }
      return this.finishNode(node, "AssignmentExpression");
    } else {
      if (ownDestructuringErrors) {
        this.checkExpressionErrors(refDestructuringErrors, true);
      }
    }
    if (oldParenAssign > -1) {
      refDestructuringErrors.parenthesizedAssign = oldParenAssign;
    }
    if (oldTrailingComma > -1) {
      refDestructuringErrors.trailingComma = oldTrailingComma;
    }
    return left;
  };
  pp$5.parseMaybeConditional = function(forInit, refDestructuringErrors) {
    var startPos = this.start, startLoc = this.startLoc;
    var expr = this.parseExprOps(forInit, refDestructuringErrors);
    if (this.checkExpressionErrors(refDestructuringErrors)) {
      return expr;
    }
    if (!(expr.type === "ArrowFunctionExpression" && expr.start === startPos) && this.eat(types$1.question)) {
      var node = this.startNodeAt(startPos, startLoc);
      node.test = expr;
      node.consequent = this.parseMaybeAssign();
      this.expect(types$1.colon);
      node.alternate = this.parseMaybeAssign(forInit);
      return this.finishNode(node, "ConditionalExpression");
    }
    return expr;
  };
  pp$5.parseExprOps = function(forInit, refDestructuringErrors) {
    var startPos = this.start, startLoc = this.startLoc;
    var expr = this.parseMaybeUnary(refDestructuringErrors, false, false, forInit);
    if (this.checkExpressionErrors(refDestructuringErrors)) {
      return expr;
    }
    return expr.start === startPos && expr.type === "ArrowFunctionExpression" ? expr : this.parseExprOp(expr, startPos, startLoc, -1, forInit);
  };
  pp$5.parseExprOp = function(left, leftStartPos, leftStartLoc, minPrec, forInit) {
    var prec = this.type.binop;
    if (prec != null && (!forInit || this.type !== types$1._in)) {
      if (prec > minPrec) {
        var logical = this.type === types$1.logicalOR || this.type === types$1.logicalAND;
        var coalesce = this.type === types$1.coalesce;
        if (coalesce) {
          prec = types$1.logicalAND.binop;
        }
        var op = this.value;
        this.next();
        var startPos = this.start, startLoc = this.startLoc;
        var right = this.parseExprOp(this.parseMaybeUnary(null, false, false, forInit), startPos, startLoc, prec, forInit);
        var node = this.buildBinary(leftStartPos, leftStartLoc, left, right, op, logical || coalesce);
        if (logical && this.type === types$1.coalesce || coalesce && (this.type === types$1.logicalOR || this.type === types$1.logicalAND)) {
          this.raiseRecoverable(this.start, "Logical expressions and coalesce expressions cannot be mixed. Wrap either by parentheses");
        }
        return this.parseExprOp(node, leftStartPos, leftStartLoc, minPrec, forInit);
      }
    }
    return left;
  };
  pp$5.buildBinary = function(startPos, startLoc, left, right, op, logical) {
    if (right.type === "PrivateIdentifier") {
      this.raise(right.start, "Private identifier can only be left side of binary expression");
    }
    var node = this.startNodeAt(startPos, startLoc);
    node.left = left;
    node.operator = op;
    node.right = right;
    return this.finishNode(node, logical ? "LogicalExpression" : "BinaryExpression");
  };
  pp$5.parseMaybeUnary = function(refDestructuringErrors, sawUnary, incDec, forInit) {
    var startPos = this.start, startLoc = this.startLoc, expr;
    if (this.isContextual("await") && this.canAwait) {
      expr = this.parseAwait(forInit);
      sawUnary = true;
    } else if (this.type.prefix) {
      var node = this.startNode(), update = this.type === types$1.incDec;
      node.operator = this.value;
      node.prefix = true;
      this.next();
      node.argument = this.parseMaybeUnary(null, true, update, forInit);
      this.checkExpressionErrors(refDestructuringErrors, true);
      if (update) {
        this.checkLValSimple(node.argument);
      } else if (this.strict && node.operator === "delete" && isLocalVariableAccess(node.argument)) {
        this.raiseRecoverable(node.start, "Deleting local variable in strict mode");
      } else if (node.operator === "delete" && isPrivateFieldAccess(node.argument)) {
        this.raiseRecoverable(node.start, "Private fields can not be deleted");
      } else {
        sawUnary = true;
      }
      expr = this.finishNode(node, update ? "UpdateExpression" : "UnaryExpression");
    } else if (!sawUnary && this.type === types$1.privateId) {
      if ((forInit || this.privateNameStack.length === 0) && this.options.checkPrivateFields) {
        this.unexpected();
      }
      expr = this.parsePrivateIdent();
      if (this.type !== types$1._in) {
        this.unexpected();
      }
    } else {
      expr = this.parseExprSubscripts(refDestructuringErrors, forInit);
      if (this.checkExpressionErrors(refDestructuringErrors)) {
        return expr;
      }
      while (this.type.postfix && !this.canInsertSemicolon()) {
        var node$1 = this.startNodeAt(startPos, startLoc);
        node$1.operator = this.value;
        node$1.prefix = false;
        node$1.argument = expr;
        this.checkLValSimple(expr);
        this.next();
        expr = this.finishNode(node$1, "UpdateExpression");
      }
    }
    if (!incDec && !(expr.type === "ArrowFunctionExpression" && expr.start === startPos) && this.eat(types$1.starstar)) {
      if (sawUnary) {
        this.unexpected(this.lastTokStart);
      } else {
        return this.buildBinary(startPos, startLoc, expr, this.parseMaybeUnary(null, false, false, forInit), "**", false);
      }
    } else {
      return expr;
    }
  };
  function isLocalVariableAccess(node) {
    return node.type === "Identifier" || node.type === "ParenthesizedExpression" && isLocalVariableAccess(node.expression);
  }
  function isPrivateFieldAccess(node) {
    return node.type === "MemberExpression" && node.property.type === "PrivateIdentifier" || node.type === "ChainExpression" && isPrivateFieldAccess(node.expression) || node.type === "ParenthesizedExpression" && isPrivateFieldAccess(node.expression);
  }
  pp$5.parseExprSubscripts = function(refDestructuringErrors, forInit) {
    var startPos = this.start, startLoc = this.startLoc;
    var oldDoubleProto = -1, oldShorthandAssign = -1;
    if (refDestructuringErrors) {
      oldDoubleProto = refDestructuringErrors.doubleProto;
      oldShorthandAssign = refDestructuringErrors.shorthandAssign;
      refDestructuringErrors.doubleProto = refDestructuringErrors.shorthandAssign = -1;
    }
    var expr = this.parseExprAtom(refDestructuringErrors, forInit);
    if (expr.type === "ArrowFunctionExpression" && this.input.slice(this.lastTokStart, this.lastTokEnd) !== ")") {
      return expr;
    }
    var result = this.parseSubscripts(expr, startPos, startLoc, false, forInit);
    if (refDestructuringErrors) {
      if (result.end > expr.end) {
        this.checkExpressionErrors(refDestructuringErrors, true);
        if (refDestructuringErrors.parenthesizedAssign >= result.start) {
          refDestructuringErrors.parenthesizedAssign = -1;
        }
        if (refDestructuringErrors.parenthesizedBind >= result.start) {
          refDestructuringErrors.parenthesizedBind = -1;
        }
        if (refDestructuringErrors.trailingComma >= result.start) {
          refDestructuringErrors.trailingComma = -1;
        }
      }
      if (oldDoubleProto > -1) {
        refDestructuringErrors.doubleProto = oldDoubleProto;
      }
      if (oldShorthandAssign > -1) {
        refDestructuringErrors.shorthandAssign = oldShorthandAssign;
      }
    }
    return result;
  };
  pp$5.parseSubscripts = function(base, startPos, startLoc, noCalls, forInit) {
    var maybeAsyncArrow = this.options.ecmaVersion >= 8 && base.type === "Identifier" && base.name === "async" && this.lastTokEnd === base.end && !this.canInsertSemicolon() && base.end - base.start === 5 && this.potentialArrowAt === base.start;
    var optionalChained = false;
    while (true) {
      var element = this.parseSubscript(base, startPos, startLoc, noCalls, maybeAsyncArrow, optionalChained, forInit);
      if (element.optional) {
        optionalChained = true;
      }
      if (element.end === base.end || element.type === "ArrowFunctionExpression") {
        if (optionalChained) {
          var chainNode = this.startNodeAt(startPos, startLoc);
          chainNode.expression = element;
          element = this.finishNode(chainNode, "ChainExpression");
        }
        return element;
      }
      base = element;
      maybeAsyncArrow = false;
    }
  };
  pp$5.shouldParseAsyncArrow = function() {
    return !this.canInsertSemicolon() && this.eat(types$1.arrow);
  };
  pp$5.parseSubscriptAsyncArrow = function(startPos, startLoc, exprList, forInit) {
    return this.parseArrowExpression(this.startNodeAt(startPos, startLoc), exprList, true, forInit);
  };
  pp$5.parseSubscript = function(base, startPos, startLoc, noCalls, maybeAsyncArrow, optionalChained, forInit) {
    var optionalSupported = this.options.ecmaVersion >= 11;
    var optional = optionalSupported && this.eat(types$1.questionDot);
    if (noCalls && optional) {
      this.raise(this.lastTokStart, "Optional chaining cannot appear in the callee of new expressions");
    }
    var computed = this.eat(types$1.bracketL);
    if (computed || optional && this.type !== types$1.parenL && this.type !== types$1.backQuote || this.eat(types$1.dot)) {
      var node = this.startNodeAt(startPos, startLoc);
      node.object = base;
      if (computed) {
        node.property = this.parseExpression();
        this.expect(types$1.bracketR);
      } else if (this.type === types$1.privateId && base.type !== "Super") {
        node.property = this.parsePrivateIdent();
      } else {
        node.property = this.parseIdent(this.options.allowReserved !== "never");
      }
      node.computed = !!computed;
      if (optionalSupported) {
        node.optional = optional;
      }
      base = this.finishNode(node, "MemberExpression");
    } else if (!noCalls && this.eat(types$1.parenL)) {
      var refDestructuringErrors = new DestructuringErrors(), oldYieldPos = this.yieldPos, oldAwaitPos = this.awaitPos, oldAwaitIdentPos = this.awaitIdentPos;
      this.yieldPos = 0;
      this.awaitPos = 0;
      this.awaitIdentPos = 0;
      var exprList = this.parseExprList(types$1.parenR, this.options.ecmaVersion >= 8, false, refDestructuringErrors);
      if (maybeAsyncArrow && !optional && this.shouldParseAsyncArrow()) {
        this.checkPatternErrors(refDestructuringErrors, false);
        this.checkYieldAwaitInDefaultParams();
        if (this.awaitIdentPos > 0) {
          this.raise(this.awaitIdentPos, "Cannot use 'await' as identifier inside an async function");
        }
        this.yieldPos = oldYieldPos;
        this.awaitPos = oldAwaitPos;
        this.awaitIdentPos = oldAwaitIdentPos;
        return this.parseSubscriptAsyncArrow(startPos, startLoc, exprList, forInit);
      }
      this.checkExpressionErrors(refDestructuringErrors, true);
      this.yieldPos = oldYieldPos || this.yieldPos;
      this.awaitPos = oldAwaitPos || this.awaitPos;
      this.awaitIdentPos = oldAwaitIdentPos || this.awaitIdentPos;
      var node$1 = this.startNodeAt(startPos, startLoc);
      node$1.callee = base;
      node$1.arguments = exprList;
      if (optionalSupported) {
        node$1.optional = optional;
      }
      base = this.finishNode(node$1, "CallExpression");
    } else if (this.type === types$1.backQuote) {
      if (optional || optionalChained) {
        this.raise(this.start, "Optional chaining cannot appear in the tag of tagged template expressions");
      }
      var node$2 = this.startNodeAt(startPos, startLoc);
      node$2.tag = base;
      node$2.quasi = this.parseTemplate({ isTagged: true });
      base = this.finishNode(node$2, "TaggedTemplateExpression");
    }
    return base;
  };
  pp$5.parseExprAtom = function(refDestructuringErrors, forInit, forNew) {
    if (this.type === types$1.slash) {
      this.readRegexp();
    }
    var node, canBeArrow = this.potentialArrowAt === this.start;
    switch (this.type) {
      case types$1._super:
        if (!this.allowSuper) {
          this.raise(this.start, "'super' keyword outside a method");
        }
        node = this.startNode();
        this.next();
        if (this.type === types$1.parenL && !this.allowDirectSuper) {
          this.raise(node.start, "super() call outside constructor of a subclass");
        }
        if (this.type !== types$1.dot && this.type !== types$1.bracketL && this.type !== types$1.parenL) {
          this.unexpected();
        }
        return this.finishNode(node, "Super");
      case types$1._this:
        node = this.startNode();
        this.next();
        return this.finishNode(node, "ThisExpression");
      case types$1.name:
        var startPos = this.start, startLoc = this.startLoc, containsEsc = this.containsEsc;
        var id = this.parseIdent(false);
        if (this.options.ecmaVersion >= 8 && !containsEsc && id.name === "async" && !this.canInsertSemicolon() && this.eat(types$1._function)) {
          this.overrideContext(types.f_expr);
          return this.parseFunction(this.startNodeAt(startPos, startLoc), 0, false, true, forInit);
        }
        if (canBeArrow && !this.canInsertSemicolon()) {
          if (this.eat(types$1.arrow)) {
            return this.parseArrowExpression(this.startNodeAt(startPos, startLoc), [id], false, forInit);
          }
          if (this.options.ecmaVersion >= 8 && id.name === "async" && this.type === types$1.name && !containsEsc && (!this.potentialArrowInForAwait || this.value !== "of" || this.containsEsc)) {
            id = this.parseIdent(false);
            if (this.canInsertSemicolon() || !this.eat(types$1.arrow)) {
              this.unexpected();
            }
            return this.parseArrowExpression(this.startNodeAt(startPos, startLoc), [id], true, forInit);
          }
        }
        return id;
      case types$1.regexp:
        var value = this.value;
        node = this.parseLiteral(value.value);
        node.regex = { pattern: value.pattern, flags: value.flags };
        return node;
      case types$1.num:
      case types$1.string:
        return this.parseLiteral(this.value);
      case types$1._null:
      case types$1._true:
      case types$1._false:
        node = this.startNode();
        node.value = this.type === types$1._null ? null : this.type === types$1._true;
        node.raw = this.type.keyword;
        this.next();
        return this.finishNode(node, "Literal");
      case types$1.parenL:
        var start = this.start, expr = this.parseParenAndDistinguishExpression(canBeArrow, forInit);
        if (refDestructuringErrors) {
          if (refDestructuringErrors.parenthesizedAssign < 0 && !this.isSimpleAssignTarget(expr)) {
            refDestructuringErrors.parenthesizedAssign = start;
          }
          if (refDestructuringErrors.parenthesizedBind < 0) {
            refDestructuringErrors.parenthesizedBind = start;
          }
        }
        return expr;
      case types$1.bracketL:
        node = this.startNode();
        this.next();
        node.elements = this.parseExprList(types$1.bracketR, true, true, refDestructuringErrors);
        return this.finishNode(node, "ArrayExpression");
      case types$1.braceL:
        this.overrideContext(types.b_expr);
        return this.parseObj(false, refDestructuringErrors);
      case types$1._function:
        node = this.startNode();
        this.next();
        return this.parseFunction(node, 0);
      case types$1._class:
        return this.parseClass(this.startNode(), false);
      case types$1._new:
        return this.parseNew();
      case types$1.backQuote:
        return this.parseTemplate();
      case types$1._import:
        if (this.options.ecmaVersion >= 11) {
          return this.parseExprImport(forNew);
        } else {
          return this.unexpected();
        }
      default:
        return this.parseExprAtomDefault();
    }
  };
  pp$5.parseExprAtomDefault = function() {
    this.unexpected();
  };
  pp$5.parseExprImport = function(forNew) {
    var node = this.startNode();
    if (this.containsEsc) {
      this.raiseRecoverable(this.start, "Escape sequence in keyword import");
    }
    this.next();
    if (this.type === types$1.parenL && !forNew) {
      return this.parseDynamicImport(node);
    } else if (this.type === types$1.dot) {
      var meta = this.startNodeAt(node.start, node.loc && node.loc.start);
      meta.name = "import";
      node.meta = this.finishNode(meta, "Identifier");
      return this.parseImportMeta(node);
    } else {
      this.unexpected();
    }
  };
  pp$5.parseDynamicImport = function(node) {
    this.next();
    node.source = this.parseMaybeAssign();
    if (this.options.ecmaVersion >= 16) {
      if (!this.eat(types$1.parenR)) {
        this.expect(types$1.comma);
        if (!this.afterTrailingComma(types$1.parenR)) {
          node.options = this.parseMaybeAssign();
          if (!this.eat(types$1.parenR)) {
            this.expect(types$1.comma);
            if (!this.afterTrailingComma(types$1.parenR)) {
              this.unexpected();
            }
          }
        } else {
          node.options = null;
        }
      } else {
        node.options = null;
      }
    } else {
      if (!this.eat(types$1.parenR)) {
        var errorPos = this.start;
        if (this.eat(types$1.comma) && this.eat(types$1.parenR)) {
          this.raiseRecoverable(errorPos, "Trailing comma is not allowed in import()");
        } else {
          this.unexpected(errorPos);
        }
      }
    }
    return this.finishNode(node, "ImportExpression");
  };
  pp$5.parseImportMeta = function(node) {
    this.next();
    var containsEsc = this.containsEsc;
    node.property = this.parseIdent(true);
    if (node.property.name !== "meta") {
      this.raiseRecoverable(node.property.start, "The only valid meta property for import is 'import.meta'");
    }
    if (containsEsc) {
      this.raiseRecoverable(node.start, "'import.meta' must not contain escaped characters");
    }
    if (this.options.sourceType !== "module" && !this.options.allowImportExportEverywhere) {
      this.raiseRecoverable(node.start, "Cannot use 'import.meta' outside a module");
    }
    return this.finishNode(node, "MetaProperty");
  };
  pp$5.parseLiteral = function(value) {
    var node = this.startNode();
    node.value = value;
    node.raw = this.input.slice(this.start, this.end);
    if (node.raw.charCodeAt(node.raw.length - 1) === 110) {
      node.bigint = node.value != null ? node.value.toString() : node.raw.slice(0, -1).replace(/_/g, "");
    }
    this.next();
    return this.finishNode(node, "Literal");
  };
  pp$5.parseParenExpression = function() {
    this.expect(types$1.parenL);
    var val = this.parseExpression();
    this.expect(types$1.parenR);
    return val;
  };
  pp$5.shouldParseArrow = function(exprList) {
    return !this.canInsertSemicolon();
  };
  pp$5.parseParenAndDistinguishExpression = function(canBeArrow, forInit) {
    var startPos = this.start, startLoc = this.startLoc, val, allowTrailingComma = this.options.ecmaVersion >= 8;
    if (this.options.ecmaVersion >= 6) {
      this.next();
      var innerStartPos = this.start, innerStartLoc = this.startLoc;
      var exprList = [], first = true, lastIsComma = false;
      var refDestructuringErrors = new DestructuringErrors(), oldYieldPos = this.yieldPos, oldAwaitPos = this.awaitPos, spreadStart;
      this.yieldPos = 0;
      this.awaitPos = 0;
      while (this.type !== types$1.parenR) {
        first ? first = false : this.expect(types$1.comma);
        if (allowTrailingComma && this.afterTrailingComma(types$1.parenR, true)) {
          lastIsComma = true;
          break;
        } else if (this.type === types$1.ellipsis) {
          spreadStart = this.start;
          exprList.push(this.parseParenItem(this.parseRestBinding()));
          if (this.type === types$1.comma) {
            this.raiseRecoverable(
              this.start,
              "Comma is not permitted after the rest element"
            );
          }
          break;
        } else {
          exprList.push(this.parseMaybeAssign(false, refDestructuringErrors, this.parseParenItem));
        }
      }
      var innerEndPos = this.lastTokEnd, innerEndLoc = this.lastTokEndLoc;
      this.expect(types$1.parenR);
      if (canBeArrow && this.shouldParseArrow(exprList) && this.eat(types$1.arrow)) {
        this.checkPatternErrors(refDestructuringErrors, false);
        this.checkYieldAwaitInDefaultParams();
        this.yieldPos = oldYieldPos;
        this.awaitPos = oldAwaitPos;
        return this.parseParenArrowList(startPos, startLoc, exprList, forInit);
      }
      if (!exprList.length || lastIsComma) {
        this.unexpected(this.lastTokStart);
      }
      if (spreadStart) {
        this.unexpected(spreadStart);
      }
      this.checkExpressionErrors(refDestructuringErrors, true);
      this.yieldPos = oldYieldPos || this.yieldPos;
      this.awaitPos = oldAwaitPos || this.awaitPos;
      if (exprList.length > 1) {
        val = this.startNodeAt(innerStartPos, innerStartLoc);
        val.expressions = exprList;
        this.finishNodeAt(val, "SequenceExpression", innerEndPos, innerEndLoc);
      } else {
        val = exprList[0];
      }
    } else {
      val = this.parseParenExpression();
    }
    if (this.options.preserveParens) {
      var par = this.startNodeAt(startPos, startLoc);
      par.expression = val;
      return this.finishNode(par, "ParenthesizedExpression");
    } else {
      return val;
    }
  };
  pp$5.parseParenItem = function(item) {
    return item;
  };
  pp$5.parseParenArrowList = function(startPos, startLoc, exprList, forInit) {
    return this.parseArrowExpression(this.startNodeAt(startPos, startLoc), exprList, false, forInit);
  };
  var empty = [];
  pp$5.parseNew = function() {
    if (this.containsEsc) {
      this.raiseRecoverable(this.start, "Escape sequence in keyword new");
    }
    var node = this.startNode();
    this.next();
    if (this.options.ecmaVersion >= 6 && this.type === types$1.dot) {
      var meta = this.startNodeAt(node.start, node.loc && node.loc.start);
      meta.name = "new";
      node.meta = this.finishNode(meta, "Identifier");
      this.next();
      var containsEsc = this.containsEsc;
      node.property = this.parseIdent(true);
      if (node.property.name !== "target") {
        this.raiseRecoverable(node.property.start, "The only valid meta property for new is 'new.target'");
      }
      if (containsEsc) {
        this.raiseRecoverable(node.start, "'new.target' must not contain escaped characters");
      }
      if (!this.allowNewDotTarget) {
        this.raiseRecoverable(node.start, "'new.target' can only be used in functions and class static block");
      }
      return this.finishNode(node, "MetaProperty");
    }
    var startPos = this.start, startLoc = this.startLoc;
    node.callee = this.parseSubscripts(this.parseExprAtom(null, false, true), startPos, startLoc, true, false);
    if (node.callee.type === "Super") {
      this.raiseRecoverable(startPos, "Invalid use of 'super'");
    }
    if (this.eat(types$1.parenL)) {
      node.arguments = this.parseExprList(types$1.parenR, this.options.ecmaVersion >= 8, false);
    } else {
      node.arguments = empty;
    }
    return this.finishNode(node, "NewExpression");
  };
  pp$5.parseTemplateElement = function(ref2) {
    var isTagged = ref2.isTagged;
    var elem = this.startNode();
    if (this.type === types$1.invalidTemplate) {
      if (!isTagged) {
        this.raiseRecoverable(this.start, "Bad escape sequence in untagged template literal");
      }
      elem.value = {
        raw: this.value.replace(/\r\n?/g, "\n"),
        cooked: null
      };
    } else {
      elem.value = {
        raw: this.input.slice(this.start, this.end).replace(/\r\n?/g, "\n"),
        cooked: this.value
      };
    }
    this.next();
    elem.tail = this.type === types$1.backQuote;
    return this.finishNode(elem, "TemplateElement");
  };
  pp$5.parseTemplate = function(ref2) {
    if (ref2 === void 0) ref2 = {};
    var isTagged = ref2.isTagged;
    if (isTagged === void 0) isTagged = false;
    var node = this.startNode();
    this.next();
    node.expressions = [];
    var curElt = this.parseTemplateElement({ isTagged });
    node.quasis = [curElt];
    while (!curElt.tail) {
      if (this.type === types$1.eof) {
        this.raise(this.pos, "Unterminated template literal");
      }
      this.expect(types$1.dollarBraceL);
      node.expressions.push(this.parseExpression());
      this.expect(types$1.braceR);
      node.quasis.push(curElt = this.parseTemplateElement({ isTagged }));
    }
    this.next();
    return this.finishNode(node, "TemplateLiteral");
  };
  pp$5.isAsyncProp = function(prop) {
    return !prop.computed && prop.key.type === "Identifier" && prop.key.name === "async" && (this.type === types$1.name || this.type === types$1.num || this.type === types$1.string || this.type === types$1.bracketL || this.type.keyword || this.options.ecmaVersion >= 9 && this.type === types$1.star) && !lineBreak.test(this.input.slice(this.lastTokEnd, this.start));
  };
  pp$5.parseObj = function(isPattern, refDestructuringErrors) {
    var node = this.startNode(), first = true, propHash = {};
    node.properties = [];
    this.next();
    while (!this.eat(types$1.braceR)) {
      if (!first) {
        this.expect(types$1.comma);
        if (this.options.ecmaVersion >= 5 && this.afterTrailingComma(types$1.braceR)) {
          break;
        }
      } else {
        first = false;
      }
      var prop = this.parseProperty(isPattern, refDestructuringErrors);
      if (!isPattern) {
        this.checkPropClash(prop, propHash, refDestructuringErrors);
      }
      node.properties.push(prop);
    }
    return this.finishNode(node, isPattern ? "ObjectPattern" : "ObjectExpression");
  };
  pp$5.parseProperty = function(isPattern, refDestructuringErrors) {
    var prop = this.startNode(), isGenerator, isAsync, startPos, startLoc;
    if (this.options.ecmaVersion >= 9 && this.eat(types$1.ellipsis)) {
      if (isPattern) {
        prop.argument = this.parseIdent(false);
        if (this.type === types$1.comma) {
          this.raiseRecoverable(this.start, "Comma is not permitted after the rest element");
        }
        return this.finishNode(prop, "RestElement");
      }
      prop.argument = this.parseMaybeAssign(false, refDestructuringErrors);
      if (this.type === types$1.comma && refDestructuringErrors && refDestructuringErrors.trailingComma < 0) {
        refDestructuringErrors.trailingComma = this.start;
      }
      return this.finishNode(prop, "SpreadElement");
    }
    if (this.options.ecmaVersion >= 6) {
      prop.method = false;
      prop.shorthand = false;
      if (isPattern || refDestructuringErrors) {
        startPos = this.start;
        startLoc = this.startLoc;
      }
      if (!isPattern) {
        isGenerator = this.eat(types$1.star);
      }
    }
    var containsEsc = this.containsEsc;
    this.parsePropertyName(prop);
    if (!isPattern && !containsEsc && this.options.ecmaVersion >= 8 && !isGenerator && this.isAsyncProp(prop)) {
      isAsync = true;
      isGenerator = this.options.ecmaVersion >= 9 && this.eat(types$1.star);
      this.parsePropertyName(prop);
    } else {
      isAsync = false;
    }
    this.parsePropertyValue(prop, isPattern, isGenerator, isAsync, startPos, startLoc, refDestructuringErrors, containsEsc);
    return this.finishNode(prop, "Property");
  };
  pp$5.parseGetterSetter = function(prop) {
    var kind = prop.key.name;
    this.parsePropertyName(prop);
    prop.value = this.parseMethod(false);
    prop.kind = kind;
    var paramCount = prop.kind === "get" ? 0 : 1;
    if (prop.value.params.length !== paramCount) {
      var start = prop.value.start;
      if (prop.kind === "get") {
        this.raiseRecoverable(start, "getter should have no params");
      } else {
        this.raiseRecoverable(start, "setter should have exactly one param");
      }
    } else {
      if (prop.kind === "set" && prop.value.params[0].type === "RestElement") {
        this.raiseRecoverable(prop.value.params[0].start, "Setter cannot use rest params");
      }
    }
  };
  pp$5.parsePropertyValue = function(prop, isPattern, isGenerator, isAsync, startPos, startLoc, refDestructuringErrors, containsEsc) {
    if ((isGenerator || isAsync) && this.type === types$1.colon) {
      this.unexpected();
    }
    if (this.eat(types$1.colon)) {
      prop.value = isPattern ? this.parseMaybeDefault(this.start, this.startLoc) : this.parseMaybeAssign(false, refDestructuringErrors);
      prop.kind = "init";
    } else if (this.options.ecmaVersion >= 6 && this.type === types$1.parenL) {
      if (isPattern) {
        this.unexpected();
      }
      prop.method = true;
      prop.value = this.parseMethod(isGenerator, isAsync);
      prop.kind = "init";
    } else if (!isPattern && !containsEsc && this.options.ecmaVersion >= 5 && !prop.computed && prop.key.type === "Identifier" && (prop.key.name === "get" || prop.key.name === "set") && (this.type !== types$1.comma && this.type !== types$1.braceR && this.type !== types$1.eq)) {
      if (isGenerator || isAsync) {
        this.unexpected();
      }
      this.parseGetterSetter(prop);
    } else if (this.options.ecmaVersion >= 6 && !prop.computed && prop.key.type === "Identifier") {
      if (isGenerator || isAsync) {
        this.unexpected();
      }
      this.checkUnreserved(prop.key);
      if (prop.key.name === "await" && !this.awaitIdentPos) {
        this.awaitIdentPos = startPos;
      }
      if (isPattern) {
        prop.value = this.parseMaybeDefault(startPos, startLoc, this.copyNode(prop.key));
      } else if (this.type === types$1.eq && refDestructuringErrors) {
        if (refDestructuringErrors.shorthandAssign < 0) {
          refDestructuringErrors.shorthandAssign = this.start;
        }
        prop.value = this.parseMaybeDefault(startPos, startLoc, this.copyNode(prop.key));
      } else {
        prop.value = this.copyNode(prop.key);
      }
      prop.kind = "init";
      prop.shorthand = true;
    } else {
      this.unexpected();
    }
  };
  pp$5.parsePropertyName = function(prop) {
    if (this.options.ecmaVersion >= 6) {
      if (this.eat(types$1.bracketL)) {
        prop.computed = true;
        prop.key = this.parseMaybeAssign();
        this.expect(types$1.bracketR);
        return prop.key;
      } else {
        prop.computed = false;
      }
    }
    return prop.key = this.type === types$1.num || this.type === types$1.string ? this.parseExprAtom() : this.parseIdent(this.options.allowReserved !== "never");
  };
  pp$5.initFunction = function(node) {
    node.id = null;
    if (this.options.ecmaVersion >= 6) {
      node.generator = node.expression = false;
    }
    if (this.options.ecmaVersion >= 8) {
      node.async = false;
    }
  };
  pp$5.parseMethod = function(isGenerator, isAsync, allowDirectSuper) {
    var node = this.startNode(), oldYieldPos = this.yieldPos, oldAwaitPos = this.awaitPos, oldAwaitIdentPos = this.awaitIdentPos;
    this.initFunction(node);
    if (this.options.ecmaVersion >= 6) {
      node.generator = isGenerator;
    }
    if (this.options.ecmaVersion >= 8) {
      node.async = !!isAsync;
    }
    this.yieldPos = 0;
    this.awaitPos = 0;
    this.awaitIdentPos = 0;
    this.enterScope(functionFlags(isAsync, node.generator) | SCOPE_SUPER | (allowDirectSuper ? SCOPE_DIRECT_SUPER : 0));
    this.expect(types$1.parenL);
    node.params = this.parseBindingList(types$1.parenR, false, this.options.ecmaVersion >= 8);
    this.checkYieldAwaitInDefaultParams();
    this.parseFunctionBody(node, false, true, false);
    this.yieldPos = oldYieldPos;
    this.awaitPos = oldAwaitPos;
    this.awaitIdentPos = oldAwaitIdentPos;
    return this.finishNode(node, "FunctionExpression");
  };
  pp$5.parseArrowExpression = function(node, params, isAsync, forInit) {
    var oldYieldPos = this.yieldPos, oldAwaitPos = this.awaitPos, oldAwaitIdentPos = this.awaitIdentPos;
    this.enterScope(functionFlags(isAsync, false) | SCOPE_ARROW);
    this.initFunction(node);
    if (this.options.ecmaVersion >= 8) {
      node.async = !!isAsync;
    }
    this.yieldPos = 0;
    this.awaitPos = 0;
    this.awaitIdentPos = 0;
    node.params = this.toAssignableList(params, true);
    this.parseFunctionBody(node, true, false, forInit);
    this.yieldPos = oldYieldPos;
    this.awaitPos = oldAwaitPos;
    this.awaitIdentPos = oldAwaitIdentPos;
    return this.finishNode(node, "ArrowFunctionExpression");
  };
  pp$5.parseFunctionBody = function(node, isArrowFunction, isMethod, forInit) {
    var isExpression = isArrowFunction && this.type !== types$1.braceL;
    var oldStrict = this.strict, useStrict = false;
    if (isExpression) {
      node.body = this.parseMaybeAssign(forInit);
      node.expression = true;
      this.checkParams(node, false);
    } else {
      var nonSimple = this.options.ecmaVersion >= 7 && !this.isSimpleParamList(node.params);
      if (!oldStrict || nonSimple) {
        useStrict = this.strictDirective(this.end);
        if (useStrict && nonSimple) {
          this.raiseRecoverable(node.start, "Illegal 'use strict' directive in function with non-simple parameter list");
        }
      }
      var oldLabels = this.labels;
      this.labels = [];
      if (useStrict) {
        this.strict = true;
      }
      this.checkParams(node, !oldStrict && !useStrict && !isArrowFunction && !isMethod && this.isSimpleParamList(node.params));
      if (this.strict && node.id) {
        this.checkLValSimple(node.id, BIND_OUTSIDE);
      }
      node.body = this.parseBlock(false, void 0, useStrict && !oldStrict);
      node.expression = false;
      this.adaptDirectivePrologue(node.body.body);
      this.labels = oldLabels;
    }
    this.exitScope();
  };
  pp$5.isSimpleParamList = function(params) {
    for (var i2 = 0, list3 = params; i2 < list3.length; i2 += 1) {
      var param = list3[i2];
      if (param.type !== "Identifier") {
        return false;
      }
    }
    return true;
  };
  pp$5.checkParams = function(node, allowDuplicates) {
    var nameHash = /* @__PURE__ */ Object.create(null);
    for (var i2 = 0, list3 = node.params; i2 < list3.length; i2 += 1) {
      var param = list3[i2];
      this.checkLValInnerPattern(param, BIND_VAR, allowDuplicates ? null : nameHash);
    }
  };
  pp$5.parseExprList = function(close, allowTrailingComma, allowEmpty, refDestructuringErrors) {
    var elts = [], first = true;
    while (!this.eat(close)) {
      if (!first) {
        this.expect(types$1.comma);
        if (allowTrailingComma && this.afterTrailingComma(close)) {
          break;
        }
      } else {
        first = false;
      }
      var elt = void 0;
      if (allowEmpty && this.type === types$1.comma) {
        elt = null;
      } else if (this.type === types$1.ellipsis) {
        elt = this.parseSpread(refDestructuringErrors);
        if (refDestructuringErrors && this.type === types$1.comma && refDestructuringErrors.trailingComma < 0) {
          refDestructuringErrors.trailingComma = this.start;
        }
      } else {
        elt = this.parseMaybeAssign(false, refDestructuringErrors);
      }
      elts.push(elt);
    }
    return elts;
  };
  pp$5.checkUnreserved = function(ref2) {
    var start = ref2.start;
    var end = ref2.end;
    var name = ref2.name;
    if (this.inGenerator && name === "yield") {
      this.raiseRecoverable(start, "Cannot use 'yield' as identifier inside a generator");
    }
    if (this.inAsync && name === "await") {
      this.raiseRecoverable(start, "Cannot use 'await' as identifier inside an async function");
    }
    if (!(this.currentThisScope().flags & SCOPE_VAR) && name === "arguments") {
      this.raiseRecoverable(start, "Cannot use 'arguments' in class field initializer");
    }
    if (this.inClassStaticBlock && (name === "arguments" || name === "await")) {
      this.raise(start, "Cannot use " + name + " in class static initialization block");
    }
    if (this.keywords.test(name)) {
      this.raise(start, "Unexpected keyword '" + name + "'");
    }
    if (this.options.ecmaVersion < 6 && this.input.slice(start, end).indexOf("\\") !== -1) {
      return;
    }
    var re = this.strict ? this.reservedWordsStrict : this.reservedWords;
    if (re.test(name)) {
      if (!this.inAsync && name === "await") {
        this.raiseRecoverable(start, "Cannot use keyword 'await' outside an async function");
      }
      this.raiseRecoverable(start, "The keyword '" + name + "' is reserved");
    }
  };
  pp$5.parseIdent = function(liberal) {
    var node = this.parseIdentNode();
    this.next(!!liberal);
    this.finishNode(node, "Identifier");
    if (!liberal) {
      this.checkUnreserved(node);
      if (node.name === "await" && !this.awaitIdentPos) {
        this.awaitIdentPos = node.start;
      }
    }
    return node;
  };
  pp$5.parseIdentNode = function() {
    var node = this.startNode();
    if (this.type === types$1.name) {
      node.name = this.value;
    } else if (this.type.keyword) {
      node.name = this.type.keyword;
      if ((node.name === "class" || node.name === "function") && (this.lastTokEnd !== this.lastTokStart + 1 || this.input.charCodeAt(this.lastTokStart) !== 46)) {
        this.context.pop();
      }
      this.type = types$1.name;
    } else {
      this.unexpected();
    }
    return node;
  };
  pp$5.parsePrivateIdent = function() {
    var node = this.startNode();
    if (this.type === types$1.privateId) {
      node.name = this.value;
    } else {
      this.unexpected();
    }
    this.next();
    this.finishNode(node, "PrivateIdentifier");
    if (this.options.checkPrivateFields) {
      if (this.privateNameStack.length === 0) {
        this.raise(node.start, "Private field '#" + node.name + "' must be declared in an enclosing class");
      } else {
        this.privateNameStack[this.privateNameStack.length - 1].used.push(node);
      }
    }
    return node;
  };
  pp$5.parseYield = function(forInit) {
    if (!this.yieldPos) {
      this.yieldPos = this.start;
    }
    var node = this.startNode();
    this.next();
    if (this.type === types$1.semi || this.canInsertSemicolon() || this.type !== types$1.star && !this.type.startsExpr) {
      node.delegate = false;
      node.argument = null;
    } else {
      node.delegate = this.eat(types$1.star);
      node.argument = this.parseMaybeAssign(forInit);
    }
    return this.finishNode(node, "YieldExpression");
  };
  pp$5.parseAwait = function(forInit) {
    if (!this.awaitPos) {
      this.awaitPos = this.start;
    }
    var node = this.startNode();
    this.next();
    node.argument = this.parseMaybeUnary(null, true, false, forInit);
    return this.finishNode(node, "AwaitExpression");
  };
  var pp$4 = Parser.prototype;
  pp$4.raise = function(pos, message) {
    var loc = getLineInfo(this.input, pos);
    message += " (" + loc.line + ":" + loc.column + ")";
    if (this.sourceFile) {
      message += " in " + this.sourceFile;
    }
    var err = new SyntaxError(message);
    err.pos = pos;
    err.loc = loc;
    err.raisedAt = this.pos;
    throw err;
  };
  pp$4.raiseRecoverable = pp$4.raise;
  pp$4.curPosition = function() {
    if (this.options.locations) {
      return new Position(this.curLine, this.pos - this.lineStart);
    }
  };
  var pp$3 = Parser.prototype;
  var Scope = function Scope2(flags) {
    this.flags = flags;
    this.var = [];
    this.lexical = [];
    this.functions = [];
  };
  pp$3.enterScope = function(flags) {
    this.scopeStack.push(new Scope(flags));
  };
  pp$3.exitScope = function() {
    this.scopeStack.pop();
  };
  pp$3.treatFunctionsAsVarInScope = function(scope) {
    return scope.flags & SCOPE_FUNCTION || !this.inModule && scope.flags & SCOPE_TOP;
  };
  pp$3.declareName = function(name, bindingType, pos) {
    var redeclared = false;
    if (bindingType === BIND_LEXICAL) {
      var scope = this.currentScope();
      redeclared = scope.lexical.indexOf(name) > -1 || scope.functions.indexOf(name) > -1 || scope.var.indexOf(name) > -1;
      scope.lexical.push(name);
      if (this.inModule && scope.flags & SCOPE_TOP) {
        delete this.undefinedExports[name];
      }
    } else if (bindingType === BIND_SIMPLE_CATCH) {
      var scope$1 = this.currentScope();
      scope$1.lexical.push(name);
    } else if (bindingType === BIND_FUNCTION) {
      var scope$2 = this.currentScope();
      if (this.treatFunctionsAsVar) {
        redeclared = scope$2.lexical.indexOf(name) > -1;
      } else {
        redeclared = scope$2.lexical.indexOf(name) > -1 || scope$2.var.indexOf(name) > -1;
      }
      scope$2.functions.push(name);
    } else {
      for (var i2 = this.scopeStack.length - 1; i2 >= 0; --i2) {
        var scope$3 = this.scopeStack[i2];
        if (scope$3.lexical.indexOf(name) > -1 && !(scope$3.flags & SCOPE_SIMPLE_CATCH && scope$3.lexical[0] === name) || !this.treatFunctionsAsVarInScope(scope$3) && scope$3.functions.indexOf(name) > -1) {
          redeclared = true;
          break;
        }
        scope$3.var.push(name);
        if (this.inModule && scope$3.flags & SCOPE_TOP) {
          delete this.undefinedExports[name];
        }
        if (scope$3.flags & SCOPE_VAR) {
          break;
        }
      }
    }
    if (redeclared) {
      this.raiseRecoverable(pos, "Identifier '" + name + "' has already been declared");
    }
  };
  pp$3.checkLocalExport = function(id) {
    if (this.scopeStack[0].lexical.indexOf(id.name) === -1 && this.scopeStack[0].var.indexOf(id.name) === -1) {
      this.undefinedExports[id.name] = id;
    }
  };
  pp$3.currentScope = function() {
    return this.scopeStack[this.scopeStack.length - 1];
  };
  pp$3.currentVarScope = function() {
    for (var i2 = this.scopeStack.length - 1; ; i2--) {
      var scope = this.scopeStack[i2];
      if (scope.flags & (SCOPE_VAR | SCOPE_CLASS_FIELD_INIT | SCOPE_CLASS_STATIC_BLOCK)) {
        return scope;
      }
    }
  };
  pp$3.currentThisScope = function() {
    for (var i2 = this.scopeStack.length - 1; ; i2--) {
      var scope = this.scopeStack[i2];
      if (scope.flags & (SCOPE_VAR | SCOPE_CLASS_FIELD_INIT | SCOPE_CLASS_STATIC_BLOCK) && !(scope.flags & SCOPE_ARROW)) {
        return scope;
      }
    }
  };
  var Node2 = function Node3(parser, pos, loc) {
    this.type = "";
    this.start = pos;
    this.end = 0;
    if (parser.options.locations) {
      this.loc = new SourceLocation(parser, loc);
    }
    if (parser.options.directSourceFile) {
      this.sourceFile = parser.options.directSourceFile;
    }
    if (parser.options.ranges) {
      this.range = [pos, 0];
    }
  };
  var pp$2 = Parser.prototype;
  pp$2.startNode = function() {
    return new Node2(this, this.start, this.startLoc);
  };
  pp$2.startNodeAt = function(pos, loc) {
    return new Node2(this, pos, loc);
  };
  function finishNodeAt(node, type, pos, loc) {
    node.type = type;
    node.end = pos;
    if (this.options.locations) {
      node.loc.end = loc;
    }
    if (this.options.ranges) {
      node.range[1] = pos;
    }
    return node;
  }
  pp$2.finishNode = function(node, type) {
    return finishNodeAt.call(this, node, type, this.lastTokEnd, this.lastTokEndLoc);
  };
  pp$2.finishNodeAt = function(node, type, pos, loc) {
    return finishNodeAt.call(this, node, type, pos, loc);
  };
  pp$2.copyNode = function(node) {
    var newNode = new Node2(this, node.start, this.startLoc);
    for (var prop in node) {
      newNode[prop] = node[prop];
    }
    return newNode;
  };
  var scriptValuesAddedInUnicode = "Berf Beria_Erfe Gara Garay Gukh Gurung_Khema Hrkt Katakana_Or_Hiragana Kawi Kirat_Rai Krai Nag_Mundari Nagm Ol_Onal Onao Sidetic Sidt Sunu Sunuwar Tai_Yo Tayo Todhri Todr Tolong_Siki Tols Tulu_Tigalari Tutg Unknown Zzzz";
  var ecma9BinaryProperties = "ASCII ASCII_Hex_Digit AHex Alphabetic Alpha Any Assigned Bidi_Control Bidi_C Bidi_Mirrored Bidi_M Case_Ignorable CI Cased Changes_When_Casefolded CWCF Changes_When_Casemapped CWCM Changes_When_Lowercased CWL Changes_When_NFKC_Casefolded CWKCF Changes_When_Titlecased CWT Changes_When_Uppercased CWU Dash Default_Ignorable_Code_Point DI Deprecated Dep Diacritic Dia Emoji Emoji_Component Emoji_Modifier Emoji_Modifier_Base Emoji_Presentation Extender Ext Grapheme_Base Gr_Base Grapheme_Extend Gr_Ext Hex_Digit Hex IDS_Binary_Operator IDSB IDS_Trinary_Operator IDST ID_Continue IDC ID_Start IDS Ideographic Ideo Join_Control Join_C Logical_Order_Exception LOE Lowercase Lower Math Noncharacter_Code_Point NChar Pattern_Syntax Pat_Syn Pattern_White_Space Pat_WS Quotation_Mark QMark Radical Regional_Indicator RI Sentence_Terminal STerm Soft_Dotted SD Terminal_Punctuation Term Unified_Ideograph UIdeo Uppercase Upper Variation_Selector VS White_Space space XID_Continue XIDC XID_Start XIDS";
  var ecma10BinaryProperties = ecma9BinaryProperties + " Extended_Pictographic";
  var ecma11BinaryProperties = ecma10BinaryProperties;
  var ecma12BinaryProperties = ecma11BinaryProperties + " EBase EComp EMod EPres ExtPict";
  var ecma13BinaryProperties = ecma12BinaryProperties;
  var ecma14BinaryProperties = ecma13BinaryProperties;
  var unicodeBinaryProperties = {
    9: ecma9BinaryProperties,
    10: ecma10BinaryProperties,
    11: ecma11BinaryProperties,
    12: ecma12BinaryProperties,
    13: ecma13BinaryProperties,
    14: ecma14BinaryProperties
  };
  var ecma14BinaryPropertiesOfStrings = "Basic_Emoji Emoji_Keycap_Sequence RGI_Emoji_Modifier_Sequence RGI_Emoji_Flag_Sequence RGI_Emoji_Tag_Sequence RGI_Emoji_ZWJ_Sequence RGI_Emoji";
  var unicodeBinaryPropertiesOfStrings = {
    9: "",
    10: "",
    11: "",
    12: "",
    13: "",
    14: ecma14BinaryPropertiesOfStrings
  };
  var unicodeGeneralCategoryValues = "Cased_Letter LC Close_Punctuation Pe Connector_Punctuation Pc Control Cc cntrl Currency_Symbol Sc Dash_Punctuation Pd Decimal_Number Nd digit Enclosing_Mark Me Final_Punctuation Pf Format Cf Initial_Punctuation Pi Letter L Letter_Number Nl Line_Separator Zl Lowercase_Letter Ll Mark M Combining_Mark Math_Symbol Sm Modifier_Letter Lm Modifier_Symbol Sk Nonspacing_Mark Mn Number N Open_Punctuation Ps Other C Other_Letter Lo Other_Number No Other_Punctuation Po Other_Symbol So Paragraph_Separator Zp Private_Use Co Punctuation P punct Separator Z Space_Separator Zs Spacing_Mark Mc Surrogate Cs Symbol S Titlecase_Letter Lt Unassigned Cn Uppercase_Letter Lu";
  var ecma9ScriptValues = "Adlam Adlm Ahom Anatolian_Hieroglyphs Hluw Arabic Arab Armenian Armn Avestan Avst Balinese Bali Bamum Bamu Bassa_Vah Bass Batak Batk Bengali Beng Bhaiksuki Bhks Bopomofo Bopo Brahmi Brah Braille Brai Buginese Bugi Buhid Buhd Canadian_Aboriginal Cans Carian Cari Caucasian_Albanian Aghb Chakma Cakm Cham Cham Cherokee Cher Common Zyyy Coptic Copt Qaac Cuneiform Xsux Cypriot Cprt Cyrillic Cyrl Deseret Dsrt Devanagari Deva Duployan Dupl Egyptian_Hieroglyphs Egyp Elbasan Elba Ethiopic Ethi Georgian Geor Glagolitic Glag Gothic Goth Grantha Gran Greek Grek Gujarati Gujr Gurmukhi Guru Han Hani Hangul Hang Hanunoo Hano Hatran Hatr Hebrew Hebr Hiragana Hira Imperial_Aramaic Armi Inherited Zinh Qaai Inscriptional_Pahlavi Phli Inscriptional_Parthian Prti Javanese Java Kaithi Kthi Kannada Knda Katakana Kana Kayah_Li Kali Kharoshthi Khar Khmer Khmr Khojki Khoj Khudawadi Sind Lao Laoo Latin Latn Lepcha Lepc Limbu Limb Linear_A Lina Linear_B Linb Lisu Lisu Lycian Lyci Lydian Lydi Mahajani Mahj Malayalam Mlym Mandaic Mand Manichaean Mani Marchen Marc Masaram_Gondi Gonm Meetei_Mayek Mtei Mende_Kikakui Mend Meroitic_Cursive Merc Meroitic_Hieroglyphs Mero Miao Plrd Modi Mongolian Mong Mro Mroo Multani Mult Myanmar Mymr Nabataean Nbat New_Tai_Lue Talu Newa Newa Nko Nkoo Nushu Nshu Ogham Ogam Ol_Chiki Olck Old_Hungarian Hung Old_Italic Ital Old_North_Arabian Narb Old_Permic Perm Old_Persian Xpeo Old_South_Arabian Sarb Old_Turkic Orkh Oriya Orya Osage Osge Osmanya Osma Pahawh_Hmong Hmng Palmyrene Palm Pau_Cin_Hau Pauc Phags_Pa Phag Phoenician Phnx Psalter_Pahlavi Phlp Rejang Rjng Runic Runr Samaritan Samr Saurashtra Saur Sharada Shrd Shavian Shaw Siddham Sidd SignWriting Sgnw Sinhala Sinh Sora_Sompeng Sora Soyombo Soyo Sundanese Sund Syloti_Nagri Sylo Syriac Syrc Tagalog Tglg Tagbanwa Tagb Tai_Le Tale Tai_Tham Lana Tai_Viet Tavt Takri Takr Tamil Taml Tangut Tang Telugu Telu Thaana Thaa Thai Thai Tibetan Tibt Tifinagh Tfng Tirhuta Tirh Ugaritic Ugar Vai Vaii Warang_Citi Wara Yi Yiii Zanabazar_Square Zanb";
  var ecma10ScriptValues = ecma9ScriptValues + " Dogra Dogr Gunjala_Gondi Gong Hanifi_Rohingya Rohg Makasar Maka Medefaidrin Medf Old_Sogdian Sogo Sogdian Sogd";
  var ecma11ScriptValues = ecma10ScriptValues + " Elymaic Elym Nandinagari Nand Nyiakeng_Puachue_Hmong Hmnp Wancho Wcho";
  var ecma12ScriptValues = ecma11ScriptValues + " Chorasmian Chrs Diak Dives_Akuru Khitan_Small_Script Kits Yezi Yezidi";
  var ecma13ScriptValues = ecma12ScriptValues + " Cypro_Minoan Cpmn Old_Uyghur Ougr Tangsa Tnsa Toto Vithkuqi Vith";
  var ecma14ScriptValues = ecma13ScriptValues + " " + scriptValuesAddedInUnicode;
  var unicodeScriptValues = {
    9: ecma9ScriptValues,
    10: ecma10ScriptValues,
    11: ecma11ScriptValues,
    12: ecma12ScriptValues,
    13: ecma13ScriptValues,
    14: ecma14ScriptValues
  };
  var data = {};
  function buildUnicodeData(ecmaVersion2) {
    var d = data[ecmaVersion2] = {
      binary: wordsRegexp(unicodeBinaryProperties[ecmaVersion2] + " " + unicodeGeneralCategoryValues),
      binaryOfStrings: wordsRegexp(unicodeBinaryPropertiesOfStrings[ecmaVersion2]),
      nonBinary: {
        General_Category: wordsRegexp(unicodeGeneralCategoryValues),
        Script: wordsRegexp(unicodeScriptValues[ecmaVersion2])
      }
    };
    d.nonBinary.Script_Extensions = d.nonBinary.Script;
    d.nonBinary.gc = d.nonBinary.General_Category;
    d.nonBinary.sc = d.nonBinary.Script;
    d.nonBinary.scx = d.nonBinary.Script_Extensions;
  }
  for (i = 0, list2 = [9, 10, 11, 12, 13, 14]; i < list2.length; i += 1) {
    ecmaVersion = list2[i];
    buildUnicodeData(ecmaVersion);
  }
  var ecmaVersion;
  var i;
  var list2;
  var pp$1 = Parser.prototype;
  var BranchID = function BranchID2(parent, base) {
    this.parent = parent;
    this.base = base || this;
  };
  BranchID.prototype.separatedFrom = function separatedFrom(alt) {
    for (var self = this; self; self = self.parent) {
      for (var other = alt; other; other = other.parent) {
        if (self.base === other.base && self !== other) {
          return true;
        }
      }
    }
    return false;
  };
  BranchID.prototype.sibling = function sibling() {
    return new BranchID(this.parent, this.base);
  };
  var RegExpValidationState = function RegExpValidationState2(parser) {
    this.parser = parser;
    this.validFlags = "gim" + (parser.options.ecmaVersion >= 6 ? "uy" : "") + (parser.options.ecmaVersion >= 9 ? "s" : "") + (parser.options.ecmaVersion >= 13 ? "d" : "") + (parser.options.ecmaVersion >= 15 ? "v" : "");
    this.unicodeProperties = data[parser.options.ecmaVersion >= 14 ? 14 : parser.options.ecmaVersion];
    this.source = "";
    this.flags = "";
    this.start = 0;
    this.switchU = false;
    this.switchV = false;
    this.switchN = false;
    this.pos = 0;
    this.lastIntValue = 0;
    this.lastStringValue = "";
    this.lastAssertionIsQuantifiable = false;
    this.numCapturingParens = 0;
    this.maxBackReference = 0;
    this.groupNames = /* @__PURE__ */ Object.create(null);
    this.backReferenceNames = [];
    this.branchID = null;
  };
  RegExpValidationState.prototype.reset = function reset(start, pattern, flags) {
    var unicodeSets = flags.indexOf("v") !== -1;
    var unicode = flags.indexOf("u") !== -1;
    this.start = start | 0;
    this.source = pattern + "";
    this.flags = flags;
    if (unicodeSets && this.parser.options.ecmaVersion >= 15) {
      this.switchU = true;
      this.switchV = true;
      this.switchN = true;
    } else {
      this.switchU = unicode && this.parser.options.ecmaVersion >= 6;
      this.switchV = false;
      this.switchN = unicode && this.parser.options.ecmaVersion >= 9;
    }
  };
  RegExpValidationState.prototype.raise = function raise(message) {
    this.parser.raiseRecoverable(this.start, "Invalid regular expression: /" + this.source + "/: " + message);
  };
  RegExpValidationState.prototype.at = function at(i2, forceU) {
    if (forceU === void 0) forceU = false;
    var s = this.source;
    var l = s.length;
    if (i2 >= l) {
      return -1;
    }
    var c = s.charCodeAt(i2);
    if (!(forceU || this.switchU) || c <= 55295 || c >= 57344 || i2 + 1 >= l) {
      return c;
    }
    var next = s.charCodeAt(i2 + 1);
    return next >= 56320 && next <= 57343 ? (c << 10) + next - 56613888 : c;
  };
  RegExpValidationState.prototype.nextIndex = function nextIndex(i2, forceU) {
    if (forceU === void 0) forceU = false;
    var s = this.source;
    var l = s.length;
    if (i2 >= l) {
      return l;
    }
    var c = s.charCodeAt(i2), next;
    if (!(forceU || this.switchU) || c <= 55295 || c >= 57344 || i2 + 1 >= l || (next = s.charCodeAt(i2 + 1)) < 56320 || next > 57343) {
      return i2 + 1;
    }
    return i2 + 2;
  };
  RegExpValidationState.prototype.current = function current(forceU) {
    if (forceU === void 0) forceU = false;
    return this.at(this.pos, forceU);
  };
  RegExpValidationState.prototype.lookahead = function lookahead(forceU) {
    if (forceU === void 0) forceU = false;
    return this.at(this.nextIndex(this.pos, forceU), forceU);
  };
  RegExpValidationState.prototype.advance = function advance(forceU) {
    if (forceU === void 0) forceU = false;
    this.pos = this.nextIndex(this.pos, forceU);
  };
  RegExpValidationState.prototype.eat = function eat(ch, forceU) {
    if (forceU === void 0) forceU = false;
    if (this.current(forceU) === ch) {
      this.advance(forceU);
      return true;
    }
    return false;
  };
  RegExpValidationState.prototype.eatChars = function eatChars(chs, forceU) {
    if (forceU === void 0) forceU = false;
    var pos = this.pos;
    for (var i2 = 0, list3 = chs; i2 < list3.length; i2 += 1) {
      var ch = list3[i2];
      var current2 = this.at(pos, forceU);
      if (current2 === -1 || current2 !== ch) {
        return false;
      }
      pos = this.nextIndex(pos, forceU);
    }
    this.pos = pos;
    return true;
  };
  pp$1.validateRegExpFlags = function(state) {
    var validFlags = state.validFlags;
    var flags = state.flags;
    var u = false;
    var v = false;
    for (var i2 = 0; i2 < flags.length; i2++) {
      var flag = flags.charAt(i2);
      if (validFlags.indexOf(flag) === -1) {
        this.raise(state.start, "Invalid regular expression flag");
      }
      if (flags.indexOf(flag, i2 + 1) > -1) {
        this.raise(state.start, "Duplicate regular expression flag");
      }
      if (flag === "u") {
        u = true;
      }
      if (flag === "v") {
        v = true;
      }
    }
    if (this.options.ecmaVersion >= 15 && u && v) {
      this.raise(state.start, "Invalid regular expression flag");
    }
  };
  function hasProp(obj) {
    for (var _ in obj) {
      return true;
    }
    return false;
  }
  pp$1.validateRegExpPattern = function(state) {
    this.regexp_pattern(state);
    if (!state.switchN && this.options.ecmaVersion >= 9 && hasProp(state.groupNames)) {
      state.switchN = true;
      this.regexp_pattern(state);
    }
  };
  pp$1.regexp_pattern = function(state) {
    state.pos = 0;
    state.lastIntValue = 0;
    state.lastStringValue = "";
    state.lastAssertionIsQuantifiable = false;
    state.numCapturingParens = 0;
    state.maxBackReference = 0;
    state.groupNames = /* @__PURE__ */ Object.create(null);
    state.backReferenceNames.length = 0;
    state.branchID = null;
    this.regexp_disjunction(state);
    if (state.pos !== state.source.length) {
      if (state.eat(
        41
        /* ) */
      )) {
        state.raise("Unmatched ')'");
      }
      if (state.eat(
        93
        /* ] */
      ) || state.eat(
        125
        /* } */
      )) {
        state.raise("Lone quantifier brackets");
      }
    }
    if (state.maxBackReference > state.numCapturingParens) {
      state.raise("Invalid escape");
    }
    for (var i2 = 0, list3 = state.backReferenceNames; i2 < list3.length; i2 += 1) {
      var name = list3[i2];
      if (!state.groupNames[name]) {
        state.raise("Invalid named capture referenced");
      }
    }
  };
  pp$1.regexp_disjunction = function(state) {
    var trackDisjunction = this.options.ecmaVersion >= 16;
    if (trackDisjunction) {
      state.branchID = new BranchID(state.branchID, null);
    }
    this.regexp_alternative(state);
    while (state.eat(
      124
      /* | */
    )) {
      if (trackDisjunction) {
        state.branchID = state.branchID.sibling();
      }
      this.regexp_alternative(state);
    }
    if (trackDisjunction) {
      state.branchID = state.branchID.parent;
    }
    if (this.regexp_eatQuantifier(state, true)) {
      state.raise("Nothing to repeat");
    }
    if (state.eat(
      123
      /* { */
    )) {
      state.raise("Lone quantifier brackets");
    }
  };
  pp$1.regexp_alternative = function(state) {
    while (state.pos < state.source.length && this.regexp_eatTerm(state)) {
    }
  };
  pp$1.regexp_eatTerm = function(state) {
    if (this.regexp_eatAssertion(state)) {
      if (state.lastAssertionIsQuantifiable && this.regexp_eatQuantifier(state)) {
        if (state.switchU) {
          state.raise("Invalid quantifier");
        }
      }
      return true;
    }
    if (state.switchU ? this.regexp_eatAtom(state) : this.regexp_eatExtendedAtom(state)) {
      this.regexp_eatQuantifier(state);
      return true;
    }
    return false;
  };
  pp$1.regexp_eatAssertion = function(state) {
    var start = state.pos;
    state.lastAssertionIsQuantifiable = false;
    if (state.eat(
      94
      /* ^ */
    ) || state.eat(
      36
      /* $ */
    )) {
      return true;
    }
    if (state.eat(
      92
      /* \ */
    )) {
      if (state.eat(
        66
        /* B */
      ) || state.eat(
        98
        /* b */
      )) {
        return true;
      }
      state.pos = start;
    }
    if (state.eat(
      40
      /* ( */
    ) && state.eat(
      63
      /* ? */
    )) {
      var lookbehind = false;
      if (this.options.ecmaVersion >= 9) {
        lookbehind = state.eat(
          60
          /* < */
        );
      }
      if (state.eat(
        61
        /* = */
      ) || state.eat(
        33
        /* ! */
      )) {
        this.regexp_disjunction(state);
        if (!state.eat(
          41
          /* ) */
        )) {
          state.raise("Unterminated group");
        }
        state.lastAssertionIsQuantifiable = !lookbehind;
        return true;
      }
    }
    state.pos = start;
    return false;
  };
  pp$1.regexp_eatQuantifier = function(state, noError) {
    if (noError === void 0) noError = false;
    if (this.regexp_eatQuantifierPrefix(state, noError)) {
      state.eat(
        63
        /* ? */
      );
      return true;
    }
    return false;
  };
  pp$1.regexp_eatQuantifierPrefix = function(state, noError) {
    return state.eat(
      42
      /* * */
    ) || state.eat(
      43
      /* + */
    ) || state.eat(
      63
      /* ? */
    ) || this.regexp_eatBracedQuantifier(state, noError);
  };
  pp$1.regexp_eatBracedQuantifier = function(state, noError) {
    var start = state.pos;
    if (state.eat(
      123
      /* { */
    )) {
      var min = 0, max = -1;
      if (this.regexp_eatDecimalDigits(state)) {
        min = state.lastIntValue;
        if (state.eat(
          44
          /* , */
        ) && this.regexp_eatDecimalDigits(state)) {
          max = state.lastIntValue;
        }
        if (state.eat(
          125
          /* } */
        )) {
          if (max !== -1 && max < min && !noError) {
            state.raise("numbers out of order in {} quantifier");
          }
          return true;
        }
      }
      if (state.switchU && !noError) {
        state.raise("Incomplete quantifier");
      }
      state.pos = start;
    }
    return false;
  };
  pp$1.regexp_eatAtom = function(state) {
    return this.regexp_eatPatternCharacters(state) || state.eat(
      46
      /* . */
    ) || this.regexp_eatReverseSolidusAtomEscape(state) || this.regexp_eatCharacterClass(state) || this.regexp_eatUncapturingGroup(state) || this.regexp_eatCapturingGroup(state);
  };
  pp$1.regexp_eatReverseSolidusAtomEscape = function(state) {
    var start = state.pos;
    if (state.eat(
      92
      /* \ */
    )) {
      if (this.regexp_eatAtomEscape(state)) {
        return true;
      }
      state.pos = start;
    }
    return false;
  };
  pp$1.regexp_eatUncapturingGroup = function(state) {
    var start = state.pos;
    if (state.eat(
      40
      /* ( */
    )) {
      if (state.eat(
        63
        /* ? */
      )) {
        if (this.options.ecmaVersion >= 16) {
          var addModifiers = this.regexp_eatModifiers(state);
          var hasHyphen = state.eat(
            45
            /* - */
          );
          if (addModifiers || hasHyphen) {
            for (var i2 = 0; i2 < addModifiers.length; i2++) {
              var modifier = addModifiers.charAt(i2);
              if (addModifiers.indexOf(modifier, i2 + 1) > -1) {
                state.raise("Duplicate regular expression modifiers");
              }
            }
            if (hasHyphen) {
              var removeModifiers = this.regexp_eatModifiers(state);
              if (!addModifiers && !removeModifiers && state.current() === 58) {
                state.raise("Invalid regular expression modifiers");
              }
              for (var i$1 = 0; i$1 < removeModifiers.length; i$1++) {
                var modifier$1 = removeModifiers.charAt(i$1);
                if (removeModifiers.indexOf(modifier$1, i$1 + 1) > -1 || addModifiers.indexOf(modifier$1) > -1) {
                  state.raise("Duplicate regular expression modifiers");
                }
              }
            }
          }
        }
        if (state.eat(
          58
          /* : */
        )) {
          this.regexp_disjunction(state);
          if (state.eat(
            41
            /* ) */
          )) {
            return true;
          }
          state.raise("Unterminated group");
        }
      }
      state.pos = start;
    }
    return false;
  };
  pp$1.regexp_eatCapturingGroup = function(state) {
    if (state.eat(
      40
      /* ( */
    )) {
      if (this.options.ecmaVersion >= 9) {
        this.regexp_groupSpecifier(state);
      } else if (state.current() === 63) {
        state.raise("Invalid group");
      }
      this.regexp_disjunction(state);
      if (state.eat(
        41
        /* ) */
      )) {
        state.numCapturingParens += 1;
        return true;
      }
      state.raise("Unterminated group");
    }
    return false;
  };
  pp$1.regexp_eatModifiers = function(state) {
    var modifiers = "";
    var ch = 0;
    while ((ch = state.current()) !== -1 && isRegularExpressionModifier(ch)) {
      modifiers += codePointToString(ch);
      state.advance();
    }
    return modifiers;
  };
  function isRegularExpressionModifier(ch) {
    return ch === 105 || ch === 109 || ch === 115;
  }
  pp$1.regexp_eatExtendedAtom = function(state) {
    return state.eat(
      46
      /* . */
    ) || this.regexp_eatReverseSolidusAtomEscape(state) || this.regexp_eatCharacterClass(state) || this.regexp_eatUncapturingGroup(state) || this.regexp_eatCapturingGroup(state) || this.regexp_eatInvalidBracedQuantifier(state) || this.regexp_eatExtendedPatternCharacter(state);
  };
  pp$1.regexp_eatInvalidBracedQuantifier = function(state) {
    if (this.regexp_eatBracedQuantifier(state, true)) {
      state.raise("Nothing to repeat");
    }
    return false;
  };
  pp$1.regexp_eatSyntaxCharacter = function(state) {
    var ch = state.current();
    if (isSyntaxCharacter(ch)) {
      state.lastIntValue = ch;
      state.advance();
      return true;
    }
    return false;
  };
  function isSyntaxCharacter(ch) {
    return ch === 36 || ch >= 40 && ch <= 43 || ch === 46 || ch === 63 || ch >= 91 && ch <= 94 || ch >= 123 && ch <= 125;
  }
  pp$1.regexp_eatPatternCharacters = function(state) {
    var start = state.pos;
    var ch = 0;
    while ((ch = state.current()) !== -1 && !isSyntaxCharacter(ch)) {
      state.advance();
    }
    return state.pos !== start;
  };
  pp$1.regexp_eatExtendedPatternCharacter = function(state) {
    var ch = state.current();
    if (ch !== -1 && ch !== 36 && !(ch >= 40 && ch <= 43) && ch !== 46 && ch !== 63 && ch !== 91 && ch !== 94 && ch !== 124) {
      state.advance();
      return true;
    }
    return false;
  };
  pp$1.regexp_groupSpecifier = function(state) {
    if (state.eat(
      63
      /* ? */
    )) {
      if (!this.regexp_eatGroupName(state)) {
        state.raise("Invalid group");
      }
      var trackDisjunction = this.options.ecmaVersion >= 16;
      var known = state.groupNames[state.lastStringValue];
      if (known) {
        if (trackDisjunction) {
          for (var i2 = 0, list3 = known; i2 < list3.length; i2 += 1) {
            var altID = list3[i2];
            if (!altID.separatedFrom(state.branchID)) {
              state.raise("Duplicate capture group name");
            }
          }
        } else {
          state.raise("Duplicate capture group name");
        }
      }
      if (trackDisjunction) {
        (known || (state.groupNames[state.lastStringValue] = [])).push(state.branchID);
      } else {
        state.groupNames[state.lastStringValue] = true;
      }
    }
  };
  pp$1.regexp_eatGroupName = function(state) {
    state.lastStringValue = "";
    if (state.eat(
      60
      /* < */
    )) {
      if (this.regexp_eatRegExpIdentifierName(state) && state.eat(
        62
        /* > */
      )) {
        return true;
      }
      state.raise("Invalid capture group name");
    }
    return false;
  };
  pp$1.regexp_eatRegExpIdentifierName = function(state) {
    state.lastStringValue = "";
    if (this.regexp_eatRegExpIdentifierStart(state)) {
      state.lastStringValue += codePointToString(state.lastIntValue);
      while (this.regexp_eatRegExpIdentifierPart(state)) {
        state.lastStringValue += codePointToString(state.lastIntValue);
      }
      return true;
    }
    return false;
  };
  pp$1.regexp_eatRegExpIdentifierStart = function(state) {
    var start = state.pos;
    var forceU = this.options.ecmaVersion >= 11;
    var ch = state.current(forceU);
    state.advance(forceU);
    if (ch === 92 && this.regexp_eatRegExpUnicodeEscapeSequence(state, forceU)) {
      ch = state.lastIntValue;
    }
    if (isRegExpIdentifierStart(ch)) {
      state.lastIntValue = ch;
      return true;
    }
    state.pos = start;
    return false;
  };
  function isRegExpIdentifierStart(ch) {
    return isIdentifierStart(ch, true) || ch === 36 || ch === 95;
  }
  pp$1.regexp_eatRegExpIdentifierPart = function(state) {
    var start = state.pos;
    var forceU = this.options.ecmaVersion >= 11;
    var ch = state.current(forceU);
    state.advance(forceU);
    if (ch === 92 && this.regexp_eatRegExpUnicodeEscapeSequence(state, forceU)) {
      ch = state.lastIntValue;
    }
    if (isRegExpIdentifierPart(ch)) {
      state.lastIntValue = ch;
      return true;
    }
    state.pos = start;
    return false;
  };
  function isRegExpIdentifierPart(ch) {
    return isIdentifierChar(ch, true) || ch === 36 || ch === 95 || ch === 8204 || ch === 8205;
  }
  pp$1.regexp_eatAtomEscape = function(state) {
    if (this.regexp_eatBackReference(state) || this.regexp_eatCharacterClassEscape(state) || this.regexp_eatCharacterEscape(state) || state.switchN && this.regexp_eatKGroupName(state)) {
      return true;
    }
    if (state.switchU) {
      if (state.current() === 99) {
        state.raise("Invalid unicode escape");
      }
      state.raise("Invalid escape");
    }
    return false;
  };
  pp$1.regexp_eatBackReference = function(state) {
    var start = state.pos;
    if (this.regexp_eatDecimalEscape(state)) {
      var n = state.lastIntValue;
      if (state.switchU) {
        if (n > state.maxBackReference) {
          state.maxBackReference = n;
        }
        return true;
      }
      if (n <= state.numCapturingParens) {
        return true;
      }
      state.pos = start;
    }
    return false;
  };
  pp$1.regexp_eatKGroupName = function(state) {
    if (state.eat(
      107
      /* k */
    )) {
      if (this.regexp_eatGroupName(state)) {
        state.backReferenceNames.push(state.lastStringValue);
        return true;
      }
      state.raise("Invalid named reference");
    }
    return false;
  };
  pp$1.regexp_eatCharacterEscape = function(state) {
    return this.regexp_eatControlEscape(state) || this.regexp_eatCControlLetter(state) || this.regexp_eatZero(state) || this.regexp_eatHexEscapeSequence(state) || this.regexp_eatRegExpUnicodeEscapeSequence(state, false) || !state.switchU && this.regexp_eatLegacyOctalEscapeSequence(state) || this.regexp_eatIdentityEscape(state);
  };
  pp$1.regexp_eatCControlLetter = function(state) {
    var start = state.pos;
    if (state.eat(
      99
      /* c */
    )) {
      if (this.regexp_eatControlLetter(state)) {
        return true;
      }
      state.pos = start;
    }
    return false;
  };
  pp$1.regexp_eatZero = function(state) {
    if (state.current() === 48 && !isDecimalDigit(state.lookahead())) {
      state.lastIntValue = 0;
      state.advance();
      return true;
    }
    return false;
  };
  pp$1.regexp_eatControlEscape = function(state) {
    var ch = state.current();
    if (ch === 116) {
      state.lastIntValue = 9;
      state.advance();
      return true;
    }
    if (ch === 110) {
      state.lastIntValue = 10;
      state.advance();
      return true;
    }
    if (ch === 118) {
      state.lastIntValue = 11;
      state.advance();
      return true;
    }
    if (ch === 102) {
      state.lastIntValue = 12;
      state.advance();
      return true;
    }
    if (ch === 114) {
      state.lastIntValue = 13;
      state.advance();
      return true;
    }
    return false;
  };
  pp$1.regexp_eatControlLetter = function(state) {
    var ch = state.current();
    if (isControlLetter(ch)) {
      state.lastIntValue = ch % 32;
      state.advance();
      return true;
    }
    return false;
  };
  function isControlLetter(ch) {
    return ch >= 65 && ch <= 90 || ch >= 97 && ch <= 122;
  }
  pp$1.regexp_eatRegExpUnicodeEscapeSequence = function(state, forceU) {
    if (forceU === void 0) forceU = false;
    var start = state.pos;
    var switchU = forceU || state.switchU;
    if (state.eat(
      117
      /* u */
    )) {
      if (this.regexp_eatFixedHexDigits(state, 4)) {
        var lead = state.lastIntValue;
        if (switchU && lead >= 55296 && lead <= 56319) {
          var leadSurrogateEnd = state.pos;
          if (state.eat(
            92
            /* \ */
          ) && state.eat(
            117
            /* u */
          ) && this.regexp_eatFixedHexDigits(state, 4)) {
            var trail = state.lastIntValue;
            if (trail >= 56320 && trail <= 57343) {
              state.lastIntValue = (lead - 55296) * 1024 + (trail - 56320) + 65536;
              return true;
            }
          }
          state.pos = leadSurrogateEnd;
          state.lastIntValue = lead;
        }
        return true;
      }
      if (switchU && state.eat(
        123
        /* { */
      ) && this.regexp_eatHexDigits(state) && state.eat(
        125
        /* } */
      ) && isValidUnicode(state.lastIntValue)) {
        return true;
      }
      if (switchU) {
        state.raise("Invalid unicode escape");
      }
      state.pos = start;
    }
    return false;
  };
  function isValidUnicode(ch) {
    return ch >= 0 && ch <= 1114111;
  }
  pp$1.regexp_eatIdentityEscape = function(state) {
    if (state.switchU) {
      if (this.regexp_eatSyntaxCharacter(state)) {
        return true;
      }
      if (state.eat(
        47
        /* / */
      )) {
        state.lastIntValue = 47;
        return true;
      }
      return false;
    }
    var ch = state.current();
    if (ch !== 99 && (!state.switchN || ch !== 107)) {
      state.lastIntValue = ch;
      state.advance();
      return true;
    }
    return false;
  };
  pp$1.regexp_eatDecimalEscape = function(state) {
    state.lastIntValue = 0;
    var ch = state.current();
    if (ch >= 49 && ch <= 57) {
      do {
        state.lastIntValue = 10 * state.lastIntValue + (ch - 48);
        state.advance();
      } while ((ch = state.current()) >= 48 && ch <= 57);
      return true;
    }
    return false;
  };
  var CharSetNone = 0;
  var CharSetOk = 1;
  var CharSetString = 2;
  pp$1.regexp_eatCharacterClassEscape = function(state) {
    var ch = state.current();
    if (isCharacterClassEscape(ch)) {
      state.lastIntValue = -1;
      state.advance();
      return CharSetOk;
    }
    var negate = false;
    if (state.switchU && this.options.ecmaVersion >= 9 && ((negate = ch === 80) || ch === 112)) {
      state.lastIntValue = -1;
      state.advance();
      var result;
      if (state.eat(
        123
        /* { */
      ) && (result = this.regexp_eatUnicodePropertyValueExpression(state)) && state.eat(
        125
        /* } */
      )) {
        if (negate && result === CharSetString) {
          state.raise("Invalid property name");
        }
        return result;
      }
      state.raise("Invalid property name");
    }
    return CharSetNone;
  };
  function isCharacterClassEscape(ch) {
    return ch === 100 || ch === 68 || ch === 115 || ch === 83 || ch === 119 || ch === 87;
  }
  pp$1.regexp_eatUnicodePropertyValueExpression = function(state) {
    var start = state.pos;
    if (this.regexp_eatUnicodePropertyName(state) && state.eat(
      61
      /* = */
    )) {
      var name = state.lastStringValue;
      if (this.regexp_eatUnicodePropertyValue(state)) {
        var value = state.lastStringValue;
        this.regexp_validateUnicodePropertyNameAndValue(state, name, value);
        return CharSetOk;
      }
    }
    state.pos = start;
    if (this.regexp_eatLoneUnicodePropertyNameOrValue(state)) {
      var nameOrValue = state.lastStringValue;
      return this.regexp_validateUnicodePropertyNameOrValue(state, nameOrValue);
    }
    return CharSetNone;
  };
  pp$1.regexp_validateUnicodePropertyNameAndValue = function(state, name, value) {
    if (!hasOwn(state.unicodeProperties.nonBinary, name)) {
      state.raise("Invalid property name");
    }
    if (!state.unicodeProperties.nonBinary[name].test(value)) {
      state.raise("Invalid property value");
    }
  };
  pp$1.regexp_validateUnicodePropertyNameOrValue = function(state, nameOrValue) {
    if (state.unicodeProperties.binary.test(nameOrValue)) {
      return CharSetOk;
    }
    if (state.switchV && state.unicodeProperties.binaryOfStrings.test(nameOrValue)) {
      return CharSetString;
    }
    state.raise("Invalid property name");
  };
  pp$1.regexp_eatUnicodePropertyName = function(state) {
    var ch = 0;
    state.lastStringValue = "";
    while (isUnicodePropertyNameCharacter(ch = state.current())) {
      state.lastStringValue += codePointToString(ch);
      state.advance();
    }
    return state.lastStringValue !== "";
  };
  function isUnicodePropertyNameCharacter(ch) {
    return isControlLetter(ch) || ch === 95;
  }
  pp$1.regexp_eatUnicodePropertyValue = function(state) {
    var ch = 0;
    state.lastStringValue = "";
    while (isUnicodePropertyValueCharacter(ch = state.current())) {
      state.lastStringValue += codePointToString(ch);
      state.advance();
    }
    return state.lastStringValue !== "";
  };
  function isUnicodePropertyValueCharacter(ch) {
    return isUnicodePropertyNameCharacter(ch) || isDecimalDigit(ch);
  }
  pp$1.regexp_eatLoneUnicodePropertyNameOrValue = function(state) {
    return this.regexp_eatUnicodePropertyValue(state);
  };
  pp$1.regexp_eatCharacterClass = function(state) {
    if (state.eat(
      91
      /* [ */
    )) {
      var negate = state.eat(
        94
        /* ^ */
      );
      var result = this.regexp_classContents(state);
      if (!state.eat(
        93
        /* ] */
      )) {
        state.raise("Unterminated character class");
      }
      if (negate && result === CharSetString) {
        state.raise("Negated character class may contain strings");
      }
      return true;
    }
    return false;
  };
  pp$1.regexp_classContents = function(state) {
    if (state.current() === 93) {
      return CharSetOk;
    }
    if (state.switchV) {
      return this.regexp_classSetExpression(state);
    }
    this.regexp_nonEmptyClassRanges(state);
    return CharSetOk;
  };
  pp$1.regexp_nonEmptyClassRanges = function(state) {
    while (this.regexp_eatClassAtom(state)) {
      var left = state.lastIntValue;
      if (state.eat(
        45
        /* - */
      ) && this.regexp_eatClassAtom(state)) {
        var right = state.lastIntValue;
        if (state.switchU && (left === -1 || right === -1)) {
          state.raise("Invalid character class");
        }
        if (left !== -1 && right !== -1 && left > right) {
          state.raise("Range out of order in character class");
        }
      }
    }
  };
  pp$1.regexp_eatClassAtom = function(state) {
    var start = state.pos;
    if (state.eat(
      92
      /* \ */
    )) {
      if (this.regexp_eatClassEscape(state)) {
        return true;
      }
      if (state.switchU) {
        var ch$1 = state.current();
        if (ch$1 === 99 || isOctalDigit(ch$1)) {
          state.raise("Invalid class escape");
        }
        state.raise("Invalid escape");
      }
      state.pos = start;
    }
    var ch = state.current();
    if (ch !== 93) {
      state.lastIntValue = ch;
      state.advance();
      return true;
    }
    return false;
  };
  pp$1.regexp_eatClassEscape = function(state) {
    var start = state.pos;
    if (state.eat(
      98
      /* b */
    )) {
      state.lastIntValue = 8;
      return true;
    }
    if (state.switchU && state.eat(
      45
      /* - */
    )) {
      state.lastIntValue = 45;
      return true;
    }
    if (!state.switchU && state.eat(
      99
      /* c */
    )) {
      if (this.regexp_eatClassControlLetter(state)) {
        return true;
      }
      state.pos = start;
    }
    return this.regexp_eatCharacterClassEscape(state) || this.regexp_eatCharacterEscape(state);
  };
  pp$1.regexp_classSetExpression = function(state) {
    var result = CharSetOk, subResult;
    if (this.regexp_eatClassSetRange(state)) ;
    else if (subResult = this.regexp_eatClassSetOperand(state)) {
      if (subResult === CharSetString) {
        result = CharSetString;
      }
      var start = state.pos;
      while (state.eatChars(
        [38, 38]
        /* && */
      )) {
        if (state.current() !== 38 && (subResult = this.regexp_eatClassSetOperand(state))) {
          if (subResult !== CharSetString) {
            result = CharSetOk;
          }
          continue;
        }
        state.raise("Invalid character in character class");
      }
      if (start !== state.pos) {
        return result;
      }
      while (state.eatChars(
        [45, 45]
        /* -- */
      )) {
        if (this.regexp_eatClassSetOperand(state)) {
          continue;
        }
        state.raise("Invalid character in character class");
      }
      if (start !== state.pos) {
        return result;
      }
    } else {
      state.raise("Invalid character in character class");
    }
    for (; ; ) {
      if (this.regexp_eatClassSetRange(state)) {
        continue;
      }
      subResult = this.regexp_eatClassSetOperand(state);
      if (!subResult) {
        return result;
      }
      if (subResult === CharSetString) {
        result = CharSetString;
      }
    }
  };
  pp$1.regexp_eatClassSetRange = function(state) {
    var start = state.pos;
    if (this.regexp_eatClassSetCharacter(state)) {
      var left = state.lastIntValue;
      if (state.eat(
        45
        /* - */
      ) && this.regexp_eatClassSetCharacter(state)) {
        var right = state.lastIntValue;
        if (left !== -1 && right !== -1 && left > right) {
          state.raise("Range out of order in character class");
        }
        return true;
      }
      state.pos = start;
    }
    return false;
  };
  pp$1.regexp_eatClassSetOperand = function(state) {
    if (this.regexp_eatClassSetCharacter(state)) {
      return CharSetOk;
    }
    return this.regexp_eatClassStringDisjunction(state) || this.regexp_eatNestedClass(state);
  };
  pp$1.regexp_eatNestedClass = function(state) {
    var start = state.pos;
    if (state.eat(
      91
      /* [ */
    )) {
      var negate = state.eat(
        94
        /* ^ */
      );
      var result = this.regexp_classContents(state);
      if (state.eat(
        93
        /* ] */
      )) {
        if (negate && result === CharSetString) {
          state.raise("Negated character class may contain strings");
        }
        return result;
      }
      state.pos = start;
    }
    if (state.eat(
      92
      /* \ */
    )) {
      var result$1 = this.regexp_eatCharacterClassEscape(state);
      if (result$1) {
        return result$1;
      }
      state.pos = start;
    }
    return null;
  };
  pp$1.regexp_eatClassStringDisjunction = function(state) {
    var start = state.pos;
    if (state.eatChars(
      [92, 113]
      /* \q */
    )) {
      if (state.eat(
        123
        /* { */
      )) {
        var result = this.regexp_classStringDisjunctionContents(state);
        if (state.eat(
          125
          /* } */
        )) {
          return result;
        }
      } else {
        state.raise("Invalid escape");
      }
      state.pos = start;
    }
    return null;
  };
  pp$1.regexp_classStringDisjunctionContents = function(state) {
    var result = this.regexp_classString(state);
    while (state.eat(
      124
      /* | */
    )) {
      if (this.regexp_classString(state) === CharSetString) {
        result = CharSetString;
      }
    }
    return result;
  };
  pp$1.regexp_classString = function(state) {
    var count = 0;
    while (this.regexp_eatClassSetCharacter(state)) {
      count++;
    }
    return count === 1 ? CharSetOk : CharSetString;
  };
  pp$1.regexp_eatClassSetCharacter = function(state) {
    var start = state.pos;
    if (state.eat(
      92
      /* \ */
    )) {
      if (this.regexp_eatCharacterEscape(state) || this.regexp_eatClassSetReservedPunctuator(state)) {
        return true;
      }
      if (state.eat(
        98
        /* b */
      )) {
        state.lastIntValue = 8;
        return true;
      }
      state.pos = start;
      return false;
    }
    var ch = state.current();
    if (ch < 0 || ch === state.lookahead() && isClassSetReservedDoublePunctuatorCharacter(ch)) {
      return false;
    }
    if (isClassSetSyntaxCharacter(ch)) {
      return false;
    }
    state.advance();
    state.lastIntValue = ch;
    return true;
  };
  function isClassSetReservedDoublePunctuatorCharacter(ch) {
    return ch === 33 || ch >= 35 && ch <= 38 || ch >= 42 && ch <= 44 || ch === 46 || ch >= 58 && ch <= 64 || ch === 94 || ch === 96 || ch === 126;
  }
  function isClassSetSyntaxCharacter(ch) {
    return ch === 40 || ch === 41 || ch === 45 || ch === 47 || ch >= 91 && ch <= 93 || ch >= 123 && ch <= 125;
  }
  pp$1.regexp_eatClassSetReservedPunctuator = function(state) {
    var ch = state.current();
    if (isClassSetReservedPunctuator(ch)) {
      state.lastIntValue = ch;
      state.advance();
      return true;
    }
    return false;
  };
  function isClassSetReservedPunctuator(ch) {
    return ch === 33 || ch === 35 || ch === 37 || ch === 38 || ch === 44 || ch === 45 || ch >= 58 && ch <= 62 || ch === 64 || ch === 96 || ch === 126;
  }
  pp$1.regexp_eatClassControlLetter = function(state) {
    var ch = state.current();
    if (isDecimalDigit(ch) || ch === 95) {
      state.lastIntValue = ch % 32;
      state.advance();
      return true;
    }
    return false;
  };
  pp$1.regexp_eatHexEscapeSequence = function(state) {
    var start = state.pos;
    if (state.eat(
      120
      /* x */
    )) {
      if (this.regexp_eatFixedHexDigits(state, 2)) {
        return true;
      }
      if (state.switchU) {
        state.raise("Invalid escape");
      }
      state.pos = start;
    }
    return false;
  };
  pp$1.regexp_eatDecimalDigits = function(state) {
    var start = state.pos;
    var ch = 0;
    state.lastIntValue = 0;
    while (isDecimalDigit(ch = state.current())) {
      state.lastIntValue = 10 * state.lastIntValue + (ch - 48);
      state.advance();
    }
    return state.pos !== start;
  };
  function isDecimalDigit(ch) {
    return ch >= 48 && ch <= 57;
  }
  pp$1.regexp_eatHexDigits = function(state) {
    var start = state.pos;
    var ch = 0;
    state.lastIntValue = 0;
    while (isHexDigit(ch = state.current())) {
      state.lastIntValue = 16 * state.lastIntValue + hexToInt(ch);
      state.advance();
    }
    return state.pos !== start;
  };
  function isHexDigit(ch) {
    return ch >= 48 && ch <= 57 || ch >= 65 && ch <= 70 || ch >= 97 && ch <= 102;
  }
  function hexToInt(ch) {
    if (ch >= 65 && ch <= 70) {
      return 10 + (ch - 65);
    }
    if (ch >= 97 && ch <= 102) {
      return 10 + (ch - 97);
    }
    return ch - 48;
  }
  pp$1.regexp_eatLegacyOctalEscapeSequence = function(state) {
    if (this.regexp_eatOctalDigit(state)) {
      var n1 = state.lastIntValue;
      if (this.regexp_eatOctalDigit(state)) {
        var n2 = state.lastIntValue;
        if (n1 <= 3 && this.regexp_eatOctalDigit(state)) {
          state.lastIntValue = n1 * 64 + n2 * 8 + state.lastIntValue;
        } else {
          state.lastIntValue = n1 * 8 + n2;
        }
      } else {
        state.lastIntValue = n1;
      }
      return true;
    }
    return false;
  };
  pp$1.regexp_eatOctalDigit = function(state) {
    var ch = state.current();
    if (isOctalDigit(ch)) {
      state.lastIntValue = ch - 48;
      state.advance();
      return true;
    }
    state.lastIntValue = 0;
    return false;
  };
  function isOctalDigit(ch) {
    return ch >= 48 && ch <= 55;
  }
  pp$1.regexp_eatFixedHexDigits = function(state, length) {
    var start = state.pos;
    state.lastIntValue = 0;
    for (var i2 = 0; i2 < length; ++i2) {
      var ch = state.current();
      if (!isHexDigit(ch)) {
        state.pos = start;
        return false;
      }
      state.lastIntValue = 16 * state.lastIntValue + hexToInt(ch);
      state.advance();
    }
    return true;
  };
  var Token = function Token2(p) {
    this.type = p.type;
    this.value = p.value;
    this.start = p.start;
    this.end = p.end;
    if (p.options.locations) {
      this.loc = new SourceLocation(p, p.startLoc, p.endLoc);
    }
    if (p.options.ranges) {
      this.range = [p.start, p.end];
    }
  };
  var pp = Parser.prototype;
  pp.next = function(ignoreEscapeSequenceInKeyword) {
    if (!ignoreEscapeSequenceInKeyword && this.type.keyword && this.containsEsc) {
      this.raiseRecoverable(this.start, "Escape sequence in keyword " + this.type.keyword);
    }
    if (this.options.onToken) {
      this.options.onToken(new Token(this));
    }
    this.lastTokEnd = this.end;
    this.lastTokStart = this.start;
    this.lastTokEndLoc = this.endLoc;
    this.lastTokStartLoc = this.startLoc;
    this.nextToken();
  };
  pp.getToken = function() {
    this.next();
    return new Token(this);
  };
  if (typeof Symbol !== "undefined") {
    pp[Symbol.iterator] = function() {
      var this$1$1 = this;
      return {
        next: function() {
          var token = this$1$1.getToken();
          return {
            done: token.type === types$1.eof,
            value: token
          };
        }
      };
    };
  }
  pp.nextToken = function() {
    var curContext = this.curContext();
    if (!curContext || !curContext.preserveSpace) {
      this.skipSpace();
    }
    this.start = this.pos;
    if (this.options.locations) {
      this.startLoc = this.curPosition();
    }
    if (this.pos >= this.input.length) {
      return this.finishToken(types$1.eof);
    }
    if (curContext.override) {
      return curContext.override(this);
    } else {
      this.readToken(this.fullCharCodeAtPos());
    }
  };
  pp.readToken = function(code) {
    if (isIdentifierStart(code, this.options.ecmaVersion >= 6) || code === 92) {
      return this.readWord();
    }
    return this.getTokenFromCode(code);
  };
  pp.fullCharCodeAt = function(pos) {
    var code = this.input.charCodeAt(pos);
    if (code <= 55295 || code >= 56320) {
      return code;
    }
    var next = this.input.charCodeAt(pos + 1);
    return next <= 56319 || next >= 57344 ? code : (code << 10) + next - 56613888;
  };
  pp.fullCharCodeAtPos = function() {
    return this.fullCharCodeAt(this.pos);
  };
  pp.skipBlockComment = function() {
    var startLoc = this.options.onComment && this.curPosition();
    var start = this.pos, end = this.input.indexOf("*/", this.pos += 2);
    if (end === -1) {
      this.raise(this.pos - 2, "Unterminated comment");
    }
    this.pos = end + 2;
    if (this.options.locations) {
      for (var nextBreak = void 0, pos = start; (nextBreak = nextLineBreak(this.input, pos, this.pos)) > -1; ) {
        ++this.curLine;
        pos = this.lineStart = nextBreak;
      }
    }
    if (this.options.onComment) {
      this.options.onComment(
        true,
        this.input.slice(start + 2, end),
        start,
        this.pos,
        startLoc,
        this.curPosition()
      );
    }
  };
  pp.skipLineComment = function(startSkip) {
    var start = this.pos;
    var startLoc = this.options.onComment && this.curPosition();
    var ch = this.input.charCodeAt(this.pos += startSkip);
    while (this.pos < this.input.length && !isNewLine(ch)) {
      ch = this.input.charCodeAt(++this.pos);
    }
    if (this.options.onComment) {
      this.options.onComment(
        false,
        this.input.slice(start + startSkip, this.pos),
        start,
        this.pos,
        startLoc,
        this.curPosition()
      );
    }
  };
  pp.skipSpace = function() {
    loop: while (this.pos < this.input.length) {
      var ch = this.input.charCodeAt(this.pos);
      switch (ch) {
        case 32:
        case 160:
          ++this.pos;
          break;
        case 13:
          if (this.input.charCodeAt(this.pos + 1) === 10) {
            ++this.pos;
          }
        case 10:
        case 8232:
        case 8233:
          ++this.pos;
          if (this.options.locations) {
            ++this.curLine;
            this.lineStart = this.pos;
          }
          break;
        case 47:
          switch (this.input.charCodeAt(this.pos + 1)) {
            case 42:
              this.skipBlockComment();
              break;
            case 47:
              this.skipLineComment(2);
              break;
            default:
              break loop;
          }
          break;
        default:
          if (ch > 8 && ch < 14 || ch >= 5760 && nonASCIIwhitespace.test(String.fromCharCode(ch))) {
            ++this.pos;
          } else {
            break loop;
          }
      }
    }
  };
  pp.finishToken = function(type, val) {
    this.end = this.pos;
    if (this.options.locations) {
      this.endLoc = this.curPosition();
    }
    var prevType = this.type;
    this.type = type;
    this.value = val;
    this.updateContext(prevType);
  };
  pp.readToken_dot = function() {
    var next = this.input.charCodeAt(this.pos + 1);
    if (next >= 48 && next <= 57) {
      return this.readNumber(true);
    }
    var next2 = this.input.charCodeAt(this.pos + 2);
    if (this.options.ecmaVersion >= 6 && next === 46 && next2 === 46) {
      this.pos += 3;
      return this.finishToken(types$1.ellipsis);
    } else {
      ++this.pos;
      return this.finishToken(types$1.dot);
    }
  };
  pp.readToken_slash = function() {
    var next = this.input.charCodeAt(this.pos + 1);
    if (this.exprAllowed) {
      ++this.pos;
      return this.readRegexp();
    }
    if (next === 61) {
      return this.finishOp(types$1.assign, 2);
    }
    return this.finishOp(types$1.slash, 1);
  };
  pp.readToken_mult_modulo_exp = function(code) {
    var next = this.input.charCodeAt(this.pos + 1);
    var size = 1;
    var tokentype = code === 42 ? types$1.star : types$1.modulo;
    if (this.options.ecmaVersion >= 7 && code === 42 && next === 42) {
      ++size;
      tokentype = types$1.starstar;
      next = this.input.charCodeAt(this.pos + 2);
    }
    if (next === 61) {
      return this.finishOp(types$1.assign, size + 1);
    }
    return this.finishOp(tokentype, size);
  };
  pp.readToken_pipe_amp = function(code) {
    var next = this.input.charCodeAt(this.pos + 1);
    if (next === code) {
      if (this.options.ecmaVersion >= 12) {
        var next2 = this.input.charCodeAt(this.pos + 2);
        if (next2 === 61) {
          return this.finishOp(types$1.assign, 3);
        }
      }
      return this.finishOp(code === 124 ? types$1.logicalOR : types$1.logicalAND, 2);
    }
    if (next === 61) {
      return this.finishOp(types$1.assign, 2);
    }
    return this.finishOp(code === 124 ? types$1.bitwiseOR : types$1.bitwiseAND, 1);
  };
  pp.readToken_caret = function() {
    var next = this.input.charCodeAt(this.pos + 1);
    if (next === 61) {
      return this.finishOp(types$1.assign, 2);
    }
    return this.finishOp(types$1.bitwiseXOR, 1);
  };
  pp.readToken_plus_min = function(code) {
    var next = this.input.charCodeAt(this.pos + 1);
    if (next === code) {
      if (next === 45 && !this.inModule && this.input.charCodeAt(this.pos + 2) === 62 && (this.lastTokEnd === 0 || lineBreak.test(this.input.slice(this.lastTokEnd, this.pos)))) {
        this.skipLineComment(3);
        this.skipSpace();
        return this.nextToken();
      }
      return this.finishOp(types$1.incDec, 2);
    }
    if (next === 61) {
      return this.finishOp(types$1.assign, 2);
    }
    return this.finishOp(types$1.plusMin, 1);
  };
  pp.readToken_lt_gt = function(code) {
    var next = this.input.charCodeAt(this.pos + 1);
    var size = 1;
    if (next === code) {
      size = code === 62 && this.input.charCodeAt(this.pos + 2) === 62 ? 3 : 2;
      if (this.input.charCodeAt(this.pos + size) === 61) {
        return this.finishOp(types$1.assign, size + 1);
      }
      return this.finishOp(types$1.bitShift, size);
    }
    if (next === 33 && code === 60 && !this.inModule && this.input.charCodeAt(this.pos + 2) === 45 && this.input.charCodeAt(this.pos + 3) === 45) {
      this.skipLineComment(4);
      this.skipSpace();
      return this.nextToken();
    }
    if (next === 61) {
      size = 2;
    }
    return this.finishOp(types$1.relational, size);
  };
  pp.readToken_eq_excl = function(code) {
    var next = this.input.charCodeAt(this.pos + 1);
    if (next === 61) {
      return this.finishOp(types$1.equality, this.input.charCodeAt(this.pos + 2) === 61 ? 3 : 2);
    }
    if (code === 61 && next === 62 && this.options.ecmaVersion >= 6) {
      this.pos += 2;
      return this.finishToken(types$1.arrow);
    }
    return this.finishOp(code === 61 ? types$1.eq : types$1.prefix, 1);
  };
  pp.readToken_question = function() {
    var ecmaVersion2 = this.options.ecmaVersion;
    if (ecmaVersion2 >= 11) {
      var next = this.input.charCodeAt(this.pos + 1);
      if (next === 46) {
        var next2 = this.input.charCodeAt(this.pos + 2);
        if (next2 < 48 || next2 > 57) {
          return this.finishOp(types$1.questionDot, 2);
        }
      }
      if (next === 63) {
        if (ecmaVersion2 >= 12) {
          var next2$1 = this.input.charCodeAt(this.pos + 2);
          if (next2$1 === 61) {
            return this.finishOp(types$1.assign, 3);
          }
        }
        return this.finishOp(types$1.coalesce, 2);
      }
    }
    return this.finishOp(types$1.question, 1);
  };
  pp.readToken_numberSign = function() {
    var ecmaVersion2 = this.options.ecmaVersion;
    var code = 35;
    if (ecmaVersion2 >= 13) {
      ++this.pos;
      code = this.fullCharCodeAtPos();
      if (isIdentifierStart(code, true) || code === 92) {
        return this.finishToken(types$1.privateId, this.readWord1());
      }
    }
    this.raise(this.pos, "Unexpected character '" + codePointToString(code) + "'");
  };
  pp.getTokenFromCode = function(code) {
    switch (code) {
      // The interpretation of a dot depends on whether it is followed
      // by a digit or another two dots.
      case 46:
        return this.readToken_dot();
      // Punctuation tokens.
      case 40:
        ++this.pos;
        return this.finishToken(types$1.parenL);
      case 41:
        ++this.pos;
        return this.finishToken(types$1.parenR);
      case 59:
        ++this.pos;
        return this.finishToken(types$1.semi);
      case 44:
        ++this.pos;
        return this.finishToken(types$1.comma);
      case 91:
        ++this.pos;
        return this.finishToken(types$1.bracketL);
      case 93:
        ++this.pos;
        return this.finishToken(types$1.bracketR);
      case 123:
        ++this.pos;
        return this.finishToken(types$1.braceL);
      case 125:
        ++this.pos;
        return this.finishToken(types$1.braceR);
      case 58:
        ++this.pos;
        return this.finishToken(types$1.colon);
      case 96:
        if (this.options.ecmaVersion < 6) {
          break;
        }
        ++this.pos;
        return this.finishToken(types$1.backQuote);
      case 48:
        var next = this.input.charCodeAt(this.pos + 1);
        if (next === 120 || next === 88) {
          return this.readRadixNumber(16);
        }
        if (this.options.ecmaVersion >= 6) {
          if (next === 111 || next === 79) {
            return this.readRadixNumber(8);
          }
          if (next === 98 || next === 66) {
            return this.readRadixNumber(2);
          }
        }
      // Anything else beginning with a digit is an integer, octal
      // number, or float.
      case 49:
      case 50:
      case 51:
      case 52:
      case 53:
      case 54:
      case 55:
      case 56:
      case 57:
        return this.readNumber(false);
      // Quotes produce strings.
      case 34:
      case 39:
        return this.readString(code);
      // Operators are parsed inline in tiny state machines. '=' (61) is
      // often referred to. `finishOp` simply skips the amount of
      // characters it is given as second argument, and returns a token
      // of the type given by its first argument.
      case 47:
        return this.readToken_slash();
      case 37:
      case 42:
        return this.readToken_mult_modulo_exp(code);
      case 124:
      case 38:
        return this.readToken_pipe_amp(code);
      case 94:
        return this.readToken_caret();
      case 43:
      case 45:
        return this.readToken_plus_min(code);
      case 60:
      case 62:
        return this.readToken_lt_gt(code);
      case 61:
      case 33:
        return this.readToken_eq_excl(code);
      case 63:
        return this.readToken_question();
      case 126:
        return this.finishOp(types$1.prefix, 1);
      case 35:
        return this.readToken_numberSign();
    }
    this.raise(this.pos, "Unexpected character '" + codePointToString(code) + "'");
  };
  pp.finishOp = function(type, size) {
    var str = this.input.slice(this.pos, this.pos + size);
    this.pos += size;
    return this.finishToken(type, str);
  };
  pp.readRegexp = function() {
    var escaped, inClass, start = this.pos;
    for (; ; ) {
      if (this.pos >= this.input.length) {
        this.raise(start, "Unterminated regular expression");
      }
      var ch = this.input.charAt(this.pos);
      if (lineBreak.test(ch)) {
        this.raise(start, "Unterminated regular expression");
      }
      if (!escaped) {
        if (ch === "[") {
          inClass = true;
        } else if (ch === "]" && inClass) {
          inClass = false;
        } else if (ch === "/" && !inClass) {
          break;
        }
        escaped = ch === "\\";
      } else {
        escaped = false;
      }
      ++this.pos;
    }
    var pattern = this.input.slice(start, this.pos);
    ++this.pos;
    var flagsStart = this.pos;
    var flags = this.readWord1();
    if (this.containsEsc) {
      this.unexpected(flagsStart);
    }
    var state = this.regexpState || (this.regexpState = new RegExpValidationState(this));
    state.reset(start, pattern, flags);
    this.validateRegExpFlags(state);
    this.validateRegExpPattern(state);
    var value = null;
    try {
      value = new RegExp(pattern, flags);
    } catch (e) {
    }
    return this.finishToken(types$1.regexp, { pattern, flags, value });
  };
  pp.readInt = function(radix, len, maybeLegacyOctalNumericLiteral) {
    var allowSeparators = this.options.ecmaVersion >= 12 && len === void 0;
    var isLegacyOctalNumericLiteral = maybeLegacyOctalNumericLiteral && this.input.charCodeAt(this.pos) === 48;
    var start = this.pos, total = 0, lastCode = 0;
    for (var i2 = 0, e = len == null ? Infinity : len; i2 < e; ++i2, ++this.pos) {
      var code = this.input.charCodeAt(this.pos), val = void 0;
      if (allowSeparators && code === 95) {
        if (isLegacyOctalNumericLiteral) {
          this.raiseRecoverable(this.pos, "Numeric separator is not allowed in legacy octal numeric literals");
        }
        if (lastCode === 95) {
          this.raiseRecoverable(this.pos, "Numeric separator must be exactly one underscore");
        }
        if (i2 === 0) {
          this.raiseRecoverable(this.pos, "Numeric separator is not allowed at the first of digits");
        }
        lastCode = code;
        continue;
      }
      if (code >= 97) {
        val = code - 97 + 10;
      } else if (code >= 65) {
        val = code - 65 + 10;
      } else if (code >= 48 && code <= 57) {
        val = code - 48;
      } else {
        val = Infinity;
      }
      if (val >= radix) {
        break;
      }
      lastCode = code;
      total = total * radix + val;
    }
    if (allowSeparators && lastCode === 95) {
      this.raiseRecoverable(this.pos - 1, "Numeric separator is not allowed at the last of digits");
    }
    if (this.pos === start || len != null && this.pos - start !== len) {
      return null;
    }
    return total;
  };
  function stringToNumber(str, isLegacyOctalNumericLiteral) {
    if (isLegacyOctalNumericLiteral) {
      return parseInt(str, 8);
    }
    return parseFloat(str.replace(/_/g, ""));
  }
  function stringToBigInt(str) {
    if (typeof BigInt !== "function") {
      return null;
    }
    return BigInt(str.replace(/_/g, ""));
  }
  pp.readRadixNumber = function(radix) {
    var start = this.pos;
    this.pos += 2;
    var val = this.readInt(radix);
    if (val == null) {
      this.raise(this.start + 2, "Expected number in radix " + radix);
    }
    if (this.options.ecmaVersion >= 11 && this.input.charCodeAt(this.pos) === 110) {
      val = stringToBigInt(this.input.slice(start, this.pos));
      ++this.pos;
    } else if (isIdentifierStart(this.fullCharCodeAtPos())) {
      this.raise(this.pos, "Identifier directly after number");
    }
    return this.finishToken(types$1.num, val);
  };
  pp.readNumber = function(startsWithDot) {
    var start = this.pos;
    if (!startsWithDot && this.readInt(10, void 0, true) === null) {
      this.raise(start, "Invalid number");
    }
    var octal = this.pos - start >= 2 && this.input.charCodeAt(start) === 48;
    if (octal && this.strict) {
      this.raise(start, "Invalid number");
    }
    var next = this.input.charCodeAt(this.pos);
    if (!octal && !startsWithDot && this.options.ecmaVersion >= 11 && next === 110) {
      var val$1 = stringToBigInt(this.input.slice(start, this.pos));
      ++this.pos;
      if (isIdentifierStart(this.fullCharCodeAtPos())) {
        this.raise(this.pos, "Identifier directly after number");
      }
      return this.finishToken(types$1.num, val$1);
    }
    if (octal && /[89]/.test(this.input.slice(start, this.pos))) {
      octal = false;
    }
    if (next === 46 && !octal) {
      ++this.pos;
      this.readInt(10);
      next = this.input.charCodeAt(this.pos);
    }
    if ((next === 69 || next === 101) && !octal) {
      next = this.input.charCodeAt(++this.pos);
      if (next === 43 || next === 45) {
        ++this.pos;
      }
      if (this.readInt(10) === null) {
        this.raise(start, "Invalid number");
      }
    }
    if (isIdentifierStart(this.fullCharCodeAtPos())) {
      this.raise(this.pos, "Identifier directly after number");
    }
    var val = stringToNumber(this.input.slice(start, this.pos), octal);
    return this.finishToken(types$1.num, val);
  };
  pp.readCodePoint = function() {
    var ch = this.input.charCodeAt(this.pos), code;
    if (ch === 123) {
      if (this.options.ecmaVersion < 6) {
        this.unexpected();
      }
      var codePos = ++this.pos;
      code = this.readHexChar(this.input.indexOf("}", this.pos) - this.pos);
      ++this.pos;
      if (code > 1114111) {
        this.invalidStringToken(codePos, "Code point out of bounds");
      }
    } else {
      code = this.readHexChar(4);
    }
    return code;
  };
  pp.readString = function(quote2) {
    var out = "", chunkStart = ++this.pos;
    for (; ; ) {
      if (this.pos >= this.input.length) {
        this.raise(this.start, "Unterminated string constant");
      }
      var ch = this.input.charCodeAt(this.pos);
      if (ch === quote2) {
        break;
      }
      if (ch === 92) {
        out += this.input.slice(chunkStart, this.pos);
        out += this.readEscapedChar(false);
        chunkStart = this.pos;
      } else if (ch === 8232 || ch === 8233) {
        if (this.options.ecmaVersion < 10) {
          this.raise(this.start, "Unterminated string constant");
        }
        ++this.pos;
        if (this.options.locations) {
          this.curLine++;
          this.lineStart = this.pos;
        }
      } else {
        if (isNewLine(ch)) {
          this.raise(this.start, "Unterminated string constant");
        }
        ++this.pos;
      }
    }
    out += this.input.slice(chunkStart, this.pos++);
    return this.finishToken(types$1.string, out);
  };
  var INVALID_TEMPLATE_ESCAPE_ERROR = {};
  pp.tryReadTemplateToken = function() {
    this.inTemplateElement = true;
    try {
      this.readTmplToken();
    } catch (err) {
      if (err === INVALID_TEMPLATE_ESCAPE_ERROR) {
        this.readInvalidTemplateToken();
      } else {
        throw err;
      }
    }
    this.inTemplateElement = false;
  };
  pp.invalidStringToken = function(position, message) {
    if (this.inTemplateElement && this.options.ecmaVersion >= 9) {
      throw INVALID_TEMPLATE_ESCAPE_ERROR;
    } else {
      this.raise(position, message);
    }
  };
  pp.readTmplToken = function() {
    var out = "", chunkStart = this.pos;
    for (; ; ) {
      if (this.pos >= this.input.length) {
        this.raise(this.start, "Unterminated template");
      }
      var ch = this.input.charCodeAt(this.pos);
      if (ch === 96 || ch === 36 && this.input.charCodeAt(this.pos + 1) === 123) {
        if (this.pos === this.start && (this.type === types$1.template || this.type === types$1.invalidTemplate)) {
          if (ch === 36) {
            this.pos += 2;
            return this.finishToken(types$1.dollarBraceL);
          } else {
            ++this.pos;
            return this.finishToken(types$1.backQuote);
          }
        }
        out += this.input.slice(chunkStart, this.pos);
        return this.finishToken(types$1.template, out);
      }
      if (ch === 92) {
        out += this.input.slice(chunkStart, this.pos);
        out += this.readEscapedChar(true);
        chunkStart = this.pos;
      } else if (isNewLine(ch)) {
        out += this.input.slice(chunkStart, this.pos);
        ++this.pos;
        switch (ch) {
          case 13:
            if (this.input.charCodeAt(this.pos) === 10) {
              ++this.pos;
            }
          case 10:
            out += "\n";
            break;
          default:
            out += String.fromCharCode(ch);
            break;
        }
        if (this.options.locations) {
          ++this.curLine;
          this.lineStart = this.pos;
        }
        chunkStart = this.pos;
      } else {
        ++this.pos;
      }
    }
  };
  pp.readInvalidTemplateToken = function() {
    for (; this.pos < this.input.length; this.pos++) {
      switch (this.input[this.pos]) {
        case "\\":
          ++this.pos;
          break;
        case "$":
          if (this.input[this.pos + 1] !== "{") {
            break;
          }
        // fall through
        case "`":
          return this.finishToken(types$1.invalidTemplate, this.input.slice(this.start, this.pos));
        case "\r":
          if (this.input[this.pos + 1] === "\n") {
            ++this.pos;
          }
        // fall through
        case "\n":
        case "\u2028":
        case "\u2029":
          ++this.curLine;
          this.lineStart = this.pos + 1;
          break;
      }
    }
    this.raise(this.start, "Unterminated template");
  };
  pp.readEscapedChar = function(inTemplate) {
    var ch = this.input.charCodeAt(++this.pos);
    ++this.pos;
    switch (ch) {
      case 110:
        return "\n";
      // 'n' -> '\n'
      case 114:
        return "\r";
      // 'r' -> '\r'
      case 120:
        return String.fromCharCode(this.readHexChar(2));
      // 'x'
      case 117:
        return codePointToString(this.readCodePoint());
      // 'u'
      case 116:
        return "	";
      // 't' -> '\t'
      case 98:
        return "\b";
      // 'b' -> '\b'
      case 118:
        return "\v";
      // 'v' -> '\u000b'
      case 102:
        return "\f";
      // 'f' -> '\f'
      case 13:
        if (this.input.charCodeAt(this.pos) === 10) {
          ++this.pos;
        }
      // '\r\n'
      case 10:
        if (this.options.locations) {
          this.lineStart = this.pos;
          ++this.curLine;
        }
        return "";
      case 56:
      case 57:
        if (this.strict) {
          this.invalidStringToken(
            this.pos - 1,
            "Invalid escape sequence"
          );
        }
        if (inTemplate) {
          var codePos = this.pos - 1;
          this.invalidStringToken(
            codePos,
            "Invalid escape sequence in template string"
          );
        }
      default:
        if (ch >= 48 && ch <= 55) {
          var octalStr = this.input.substr(this.pos - 1, 3).match(/^[0-7]+/)[0];
          var octal = parseInt(octalStr, 8);
          if (octal > 255) {
            octalStr = octalStr.slice(0, -1);
            octal = parseInt(octalStr, 8);
          }
          this.pos += octalStr.length - 1;
          ch = this.input.charCodeAt(this.pos);
          if ((octalStr !== "0" || ch === 56 || ch === 57) && (this.strict || inTemplate)) {
            this.invalidStringToken(
              this.pos - 1 - octalStr.length,
              inTemplate ? "Octal literal in template string" : "Octal literal in strict mode"
            );
          }
          return String.fromCharCode(octal);
        }
        if (isNewLine(ch)) {
          if (this.options.locations) {
            this.lineStart = this.pos;
            ++this.curLine;
          }
          return "";
        }
        return String.fromCharCode(ch);
    }
  };
  pp.readHexChar = function(len) {
    var codePos = this.pos;
    var n = this.readInt(16, len);
    if (n === null) {
      this.invalidStringToken(codePos, "Bad character escape sequence");
    }
    return n;
  };
  pp.readWord1 = function() {
    this.containsEsc = false;
    var word = "", first = true, chunkStart = this.pos;
    var astral = this.options.ecmaVersion >= 6;
    while (this.pos < this.input.length) {
      var ch = this.fullCharCodeAtPos();
      if (isIdentifierChar(ch, astral)) {
        this.pos += ch <= 65535 ? 1 : 2;
      } else if (ch === 92) {
        this.containsEsc = true;
        word += this.input.slice(chunkStart, this.pos);
        var escStart = this.pos;
        if (this.input.charCodeAt(++this.pos) !== 117) {
          this.invalidStringToken(this.pos, "Expecting Unicode escape sequence \\uXXXX");
        }
        ++this.pos;
        var esc = this.readCodePoint();
        if (!(first ? isIdentifierStart : isIdentifierChar)(esc, astral)) {
          this.invalidStringToken(escStart, "Invalid Unicode escape");
        }
        word += codePointToString(esc);
        chunkStart = this.pos;
      } else {
        break;
      }
      first = false;
    }
    return word + this.input.slice(chunkStart, this.pos);
  };
  pp.readWord = function() {
    var word = this.readWord1();
    var type = types$1.name;
    if (this.keywords.test(word)) {
      type = keywords[word];
    }
    return this.finishToken(type, word);
  };
  var version = "8.19.0";
  Parser.acorn = {
    Parser,
    version,
    defaultOptions,
    Position,
    SourceLocation,
    getLineInfo,
    Node: Node2,
    TokenType,
    tokTypes: types$1,
    keywordTypes: keywords,
    TokContext,
    tokContexts: types,
    isIdentifierChar,
    isIdentifierStart,
    Token,
    isNewLine,
    lineBreak,
    lineBreakG,
    nonASCIIwhitespace
  };
  function parse3(input, options) {
    return Parser.parse(input, options);
  }

  // src/background/javascript.ts
  function replBody(code) {
    let program;
    try {
      program = parse3(code, {
        ecmaVersion: "latest",
        sourceType: "script",
        allowAwaitOutsideFunction: true
      });
    } catch (error) {
      throw thrown({
        ok: false,
        error: `SyntaxError: ${error.message}`,
        code: "invalid_argument"
      });
    }
    let last = program.body.at(-1);
    if (last?.type !== "ExpressionStatement") return code;
    let { start, end } = last.expression;
    return `${code.slice(0, last.start)}return (${code.slice(start, end)});${code.slice(last.end)}`;
  }

  // src/webview/index.ts
  var methods = ["GET", "POST", "PUT", "PATCH", "DELETE"];
  performance.setResourceTimingBufferSize(2e3);
  function listResources() {
    let entries = [
      ...performance.getEntriesByType("navigation"),
      ...performance.getEntriesByType("resource")
    ];
    return entries.map((entry, id) => ({
      id,
      url: entry.name,
      kind: entry.initiatorType,
      status: entry.responseStatus || null,
      time: Math.round(performance.timeOrigin + entry.startTime),
      durationMs: Math.round(entry.duration)
    }));
  }
  function recordFor(resource) {
    let capturing = false;
    for (let method of methods) {
      let answer = takeBody(resource.url, method, resource.time);
      capturing = answer.capturing;
      if (answer.record) return answer;
    }
    return { ok: true, capturing, record: null };
  }
  var captured = /* @__PURE__ */ new Set(["fetch", "xmlhttprequest"]);
  function handleHost(request) {
    if (request.op === "resources") {
      let pattern = request.pattern;
      let kept = listResources().filter(
        (resource) => pattern === null || resource.url.includes(pattern)
      );
      let resources = kept.slice(-request.limit).map((resource) => ({
        ...resource,
        status: resource.status ?? (captured.has(resource.kind) ? recordFor(resource).record?.status ?? null : null)
      }));
      return { ok: true, resources, matched: kept.length };
    }
    if (request.op === "resourceBody") {
      let resource = listResources()[request.id];
      if (!resource)
        return {
          ok: false,
          error: `no request has id ${request.id}`,
          code: "invalid_argument"
        };
      return recordFor(resource);
    }
    if (request.op === "refAt") {
      let element = deepElementFromPoint(request);
      if (!element)
        return {
          ok: false,
          error: `nothing is at (${request.left}, ${request.top})`,
          code: "invalid_argument"
        };
      return { ok: true, ref: refFor(element) };
    }
    return { ok: true, body: replBody(request.code) };
  }
  var hostOps = /* @__PURE__ */ new Set(["resources", "resourceBody", "refAt", "replBody"]);
  globalThis.safaripilot = async (request) => {
    if (!hostOps.has(request.op))
      return await page.handle(request);
    try {
      return handleHost(request);
    } catch (error) {
      return failureFrom(error) ?? {
        ok: false,
        error: `${request.op} failed: ${error instanceof Error ? error.message : String(error)}`,
        code: "failed"
      };
    }
  };
})();
