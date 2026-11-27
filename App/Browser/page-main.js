"use strict";
(() => {
  // src/main/console.ts
  var takeEvent = "safaripilot-console-take";
  var takeClearEvent = "safaripilot-console-take-clear";
  var entriesEvent = "safaripilot-console-entries";
  var maxEntries = 1e3;
  var maxText = 2e3;
  var maxNested = 200;
  var maxItems = 20;
  var maxDepth = 2;
  var wrapped = ["log", "info", "warn", "error", "debug"];
  var locationPattern = /([^\s@(]+:\d+:\d+)\)?$/;
  var tagOf = Object.prototype.toString;
  var clip = (text, max) => text.length > max ? `${text.slice(0, max)}... (${text.length - max} more characters)` : text;
  function callerOf(stack, own) {
    for (let line of stack.split("\n")) {
      let location = line.trim().match(locationPattern)?.[1];
      if (location && (own === null || !location.startsWith(own)))
        return location;
    }
    return null;
  }
  function formatValue(value, depth, seen) {
    if (typeof value === "string")
      return depth === 0 ? value : JSON.stringify(clip(value, maxNested));
    if (typeof value === "bigint") return `${value}n`;
    if (typeof value === "function")
      return `[function ${value.name || "anonymous"}]`;
    if (typeof value !== "object" || value === null) return String(value);
    if (seen.has(value)) return "[circular]";
    try {
      let tag = tagOf.call(value).slice(8, -1);
      let object = value;
      if (tag === "Error" || tag === "DOMException") {
        let head = `${object.name}: ${object.message}`;
        let stack = typeof object.stack === "string" ? object.stack : "";
        if (depth > 0 || !stack) return head;
        return stack.includes(head) ? stack : `${head}
${stack}`;
      }
      if (tag === "Date")
        return isNaN(+value) ? "Invalid Date" : value.toISOString();
      if (tag === "RegExp") return String(value);
      if (typeof object.nodeType === "number" && typeof object.nodeName === "string") {
        if (object.nodeType !== 1) return `${object.nodeName}`.toLowerCase();
        let element = value;
        let id = element.id ? `#${element.id}` : "";
        let classes = [...element.classList].map((name) => `.${name}`).join("");
        return `<${element.localName}${id}${classes}>`;
      }
      if (object.window === value) return "[Window]";
      let isArray = Array.isArray(value);
      if (depth >= maxDepth)
        return isArray ? `[Array(${value.length})]` : `[${tag}]`;
      seen.add(value);
      let item = (read) => {
        try {
          return formatValue(read(), depth + 1, seen);
        } catch {
          return "[threw]";
        }
      };
      let list = (items, total) => total > maxItems ? [...items, `... ${total - maxItems} more`].join(", ") : items.join(", ");
      let shown;
      if (isArray) {
        let array = value;
        let items = array.slice(0, maxItems).map((_, index) => item(() => array[index]));
        shown = `[${list(items, array.length)}]`;
      } else if (tag === "Map" || tag === "Set") {
        let collection = value;
        let pairs = [...collection.entries()].slice(0, maxItems);
        let items = pairs.map(
          ([key, entry]) => tag === "Map" ? `${item(() => key)} => ${item(() => entry)}` : item(() => entry)
        );
        shown = `${tag}(${collection.size}) {${list(items, collection.size)}}`;
      } else {
        let keys = Object.keys(value);
        let items = keys.slice(0, maxItems).map((key) => `${key}: ${item(() => object[key])}`);
        let prefix = tag === "Object" ? "" : `${tag} `;
        shown = `${prefix}{${list(items, keys.length)}}`;
      }
      seen.delete(value);
      return shown;
    } catch {
      seen.delete(value);
      return "[unreadable]";
    }
  }
  function formatArgs(args) {
    let rest = [...args];
    let parts = [];
    if (typeof rest[0] === "string" && rest.length > 1) {
      let format = rest.shift();
      parts.push(
        format.replace(/%([sdifoOc%])/g, (match, kind) => {
          if (kind === "%") return "%";
          if (!rest.length) return match;
          let value = rest.shift();
          if (kind === "c") return "";
          if (kind === "d" || kind === "i")
            return String(Math.trunc(Number(value)));
          if (kind === "f") return String(Number(value));
          return formatValue(value, 0, /* @__PURE__ */ new Set());
        })
      );
    }
    parts.push(...rest.map((value) => formatValue(value, 0, /* @__PURE__ */ new Set())));
    return clip(parts.join(" "), maxText);
  }
  function installCapture(page) {
    let buffer = [];
    let dropped = 0;
    let formatting = false;
    let now = Date.now;
    let apply = Reflect.apply;
    let stringify = JSON.stringify;
    let later = page.setTimeout.bind(page);
    let dispatch = page.dispatchEvent.bind(page);
    let listen = page.addEventListener.bind(page);
    let Custom = page.CustomEvent;
    let ErrorEventType = page.ErrorEvent;
    let ownLocation = callerOf(new Error().stack ?? "", null);
    let own = ownLocation?.replace(/:\d+:\d+$/, "") ?? null;
    let record = (level, text, source, time) => {
      if (buffer.length >= maxEntries) {
        buffer.shift();
        dropped++;
      }
      buffer.push({ level, text, time, url: page.location.href, source });
    };
    for (let level of wrapped) {
      let original = page.console[level];
      if (typeof original !== "function") continue;
      page.console[level] = {
        [level](...args) {
          try {
            arm();
          } catch {
          }
          if (!formatting) {
            formatting = true;
            try {
              record(
                level,
                formatArgs(args),
                callerOf(new Error().stack ?? "", own),
                now()
              );
            } catch {
            }
            formatting = false;
          }
          return apply(original, this, args);
        }
      }[level];
    }
    let onError = (event) => {
      if (!(event instanceof ErrorEventType)) return;
      let time = now();
      later(() => {
        try {
          if (event.defaultPrevented) return;
          let thrown = event.error;
          let text = thrown === void 0 || thrown === null ? event.message.replace(/^Uncaught /, "") : formatValue(thrown, 0, /* @__PURE__ */ new Set());
          let source = event.filename ? `${event.filename}:${event.lineno}:${event.colno}` : null;
          record("exception", clip(`Uncaught ${text}`, maxText), source, time);
        } catch {
        }
      });
    };
    let onRejection = (event) => {
      let time = now();
      later(() => {
        try {
          if (event.defaultPrevented) return;
          let reason = event.reason;
          let stack = reason?.stack;
          let source = typeof stack === "string" ? callerOf(stack, own) : null;
          let text = `Unhandled Promise Rejection: ${formatValue(reason, 0, /* @__PURE__ */ new Set())}`;
          record("exception", clip(text, maxText), source, time);
        } catch {
        }
      });
    };
    let answer = (clear) => () => {
      let detail = stringify({ entries: buffer, dropped });
      if (clear) {
        buffer = [];
        dropped = 0;
      }
      dispatch(new Custom(entriesEvent, { detail }));
    };
    let take = answer(false);
    let takeClear = answer(true);
    function arm() {
      listen("error", onError, true);
      listen("unhandledrejection", onRejection, true);
      listen(takeEvent, take, true);
      listen(takeClearEvent, takeClear, true);
    }
    arm();
  }

  // src/main/network.ts
  var takeEvent2 = "safaripilot-network-take";
  var pendingEvent = "safaripilot-network-pending";
  var answerEvent = "safaripilot-network-answer";
  var fetchEvent = "safaripilot-fetch";
  var fetchAnswerEvent = "safaripilot-fetch-answer";
  var maxRecords = 200;
  var maxBody = 1e5;
  var maxFetchBody = 5e6;
  var matchWindowMs = 1e4;
  var textual = /^text\/(?!event-stream)|[/+](json|xml)\b|javascript|ecmascript|x-www-form-urlencoded|graphql/i;
  var isTextual = (contentType) => textual.test(contentType);
  var clip2 = (text, limit = maxBody) => text.length > limit ? { text: text.slice(0, limit), cut: true } : { text, cut: false };
  function describeBody(body, page) {
    if (body === void 0 || body === null) return null;
    if (typeof body === "string") return clip2(body).text;
    if (body instanceof page.URLSearchParams) return clip2(body.toString()).text;
    if (body instanceof page.FormData) {
      let fields = [...body].map(
        ([name, value]) => typeof value === "string" ? `${name}=${value}` : `${name}=[file ${value.name}, ${value.size} bytes]`
      );
      return clip2(fields.join("&")).text;
    }
    if (body instanceof page.Blob)
      return `[blob ${body.type || "untyped"}, ${body.size} bytes]`;
    if (body instanceof page.ArrayBuffer || ArrayBuffer.isView(body))
      return `[${body.byteLength} bytes]`;
    if (body instanceof page.ReadableStream) return "[stream]";
    if (body instanceof page.Document) return "[document]";
    return `[${Object.prototype.toString.call(body).slice(8, -1)}]`;
  }
  function closest(records, url, method, time) {
    let best = null;
    for (let record of records) {
      if (record.url !== url || record.method !== method) continue;
      let gap = Math.abs(record.time - time);
      if (gap <= matchWindowMs && (!best || gap < Math.abs(best.time - time)))
        best = record;
    }
    return best;
  }
  function installNetworkCapture(page) {
    let records = [];
    let now = Date.now;
    let apply = Reflect.apply;
    let stringify = JSON.stringify;
    let parse = JSON.parse;
    let dispatch = page.dispatchEvent.bind(page);
    let listen = page.addEventListener.bind(page);
    let Custom = page.CustomEvent;
    let Url = page.URL;
    let Decoder = page.TextDecoder;
    let RequestType = page.Request;
    let Search = page.URLSearchParams;
    let Abort = page.AbortController;
    let later = page.setTimeout.bind(page);
    let cancelLater = page.clearTimeout.bind(page);
    let originalFetch = page.fetch;
    let xhr = page.XMLHttpRequest.prototype;
    let originalOpen = xhr.open;
    let originalSend = xhr.send;
    let opened = /* @__PURE__ */ new WeakMap();
    let exactBodies = /* @__PURE__ */ new WeakSet();
    let keepBody = (record, body) => {
      if ((typeof body === "string" || body instanceof Search) && String(body).length <= maxBody)
        exactBodies.add(record);
    };
    let unfinished = /* @__PURE__ */ new Set();
    let track = () => {
      let call = { time: now() };
      unfinished.add(call);
      return () => unfinished.delete(call);
    };
    let absolute = (url) => {
      try {
        return new Url(url, page.location.href).href;
      } catch {
        return url;
      }
    };
    let start = (method, url, requestBody) => {
      let record = {
        method: method.toUpperCase(),
        url: absolute(url),
        time: now(),
        requestBody,
        status: null,
        contentType: "",
        responseBody: null,
        truncated: false,
        note: "still loading"
      };
      if (records.length >= maxRecords) records.shift();
      records.push(record);
      return record;
    };
    let finish = (record, status, contentType) => {
      record.status = status;
      record.contentType = contentType;
      record.note = isTextual(contentType) ? null : `not text (${contentType || "no content type"})`;
    };
    let readText = async (body, limit = maxBody) => {
      let reader = body?.getReader();
      let decoder = new Decoder();
      let text = "";
      while (reader) {
        let { done, value } = await reader.read();
        if (done) break;
        text += decoder.decode(value, { stream: true });
        if (text.length > limit) {
          reader.cancel().catch(() => {
          });
          return { text: text.slice(0, limit), cut: true };
        }
      }
      return clip2(text + decoder.decode(), limit);
    };
    let readResponse = async (record, response) => {
      finish(record, response.status, response.headers.get("content-type") ?? "");
      if (record.note !== null) return;
      let { text, cut } = await readText(response.clone().body);
      record.responseBody = text;
      record.truncated = cut;
    };
    page.fetch = {
      fetch(...args) {
        try {
          arm();
          let [input, init] = args;
          let request = input instanceof RequestType ? input : null;
          let method = init?.method ?? request?.method ?? "GET";
          let url = request ? request.url : String(input);
          let body = init?.body ?? null;
          let record = start(method, url, describeBody(body, page));
          keepBody(record, body);
          if (body === null && request?.body)
            request.clone().text().then((text) => record.requestBody = clip2(text).text).catch(() => {
            });
          let done = track();
          let pending;
          try {
            pending = apply(originalFetch, this, args);
          } catch (error) {
            done();
            throw error;
          }
          pending.then(
            (response) => readResponse(record, response).catch(
              (error) => record.note = `body not read: ${error}`
            ),
            (error) => record.note = `failed: ${error}`
          ).finally(done);
          return pending;
        } catch {
          return apply(originalFetch, this, args);
        }
      }
    }.fetch;
    xhr.open = function open(...args) {
      try {
        opened.set(this, { method: String(args[0]), url: String(args[1]) });
      } catch {
      }
      return apply(originalOpen, this, args);
    };
    xhr.send = function send(...args) {
      let done = () => {
      };
      try {
        arm();
        done = track();
        this.addEventListener("loadend", () => done());
        let call = opened.get(this);
        if (call) {
          let record = start(call.method, call.url, describeBody(args[0], page));
          keepBody(record, args[0]);
          this.addEventListener("loadend", () => {
            try {
              if (this.status === 0) {
                record.note = "failed: no response";
                return;
              }
              finish(
                record,
                this.status,
                this.getResponseHeader("content-type") ?? ""
              );
              if (record.note !== null) return;
              let type = this.responseType;
              if (type !== "" && type !== "text" && type !== "json") {
                record.note = `not text (responseType ${type})`;
                return;
              }
              let text = type === "json" ? stringify(this.response) : this.responseText;
              let clipped = clip2(text);
              record.responseBody = clipped.text;
              record.truncated = clipped.cut;
            } catch (error) {
              record.note = `body not read: ${error}`;
            }
          });
        }
      } catch {
      }
      try {
        return apply(originalSend, this, args);
      } catch (error) {
        done();
        throw error;
      }
    };
    let take = (event) => {
      let answer = "null";
      try {
        let { url, method, time } = parse(String(event.detail));
        answer = stringify(
          closest(records, String(url), String(method), Number(time))
        );
      } catch {
      }
      dispatch(new Custom(answerEvent, { detail: answer }));
    };
    let countPending = (event) => {
      let answer = "null";
      try {
        let since = Number(parse(String(event.detail)).since);
        answer = String(
          [...unfinished].filter((call) => call.time >= since).length
        );
      } catch {
      }
      dispatch(new Custom(answerEvent, { detail: answer }));
    };
    let failing = (error, code = "failed") => ({ error, code });
    let readBody = async (answer, response) => {
      if (!response.body) return;
      if (isTextual(answer.contentType)) {
        let { text, cut } = await readText(response.body, maxFetchBody);
        answer.body = text;
        answer.size = text.length;
        answer.truncated = cut;
        return;
      }
      let reader = response.body.getReader();
      answer.binary = true;
      for (; ; ) {
        let part = await reader.read();
        if (part.done) break;
        answer.size += part.value.byteLength;
      }
    };
    let sendFromPage = async (request) => {
      let method = String(request.method);
      let body = request.body === null ? null : String(request.body);
      let replay = request.replay;
      if (replay && body === null && method !== "GET" && method !== "HEAD") {
        let record = closest(
          records,
          String(replay.url),
          String(replay.method),
          Number(replay.time)
        );
        if (!record)
          throw failing(
            "no fetch or XMLHttpRequest call in this frame matches the logged request, so its body is unknown; pass body",
            "invalid_argument"
          );
        if (record.requestBody !== null && !exactBodies.has(record))
          throw failing(
            `the logged request's body was not kept as text (form data, a file, binary data or over ${maxBody} characters); pass body`,
            "invalid_argument"
          );
        body = record.requestBody;
      }
      let timeoutMs = Number(request.timeoutMs);
      let controller = new Abort();
      let timer = later(() => controller.abort(), timeoutMs);
      try {
        let response = await apply(originalFetch, page, [
          String(request.url),
          {
            method,
            headers: request.headers.map(
              ({ name, value }) => [String(name), String(value)]
            ),
            body,
            credentials: "include",
            signal: controller.signal
          }
        ]);
        let answer = {
          ok: true,
          status: response.status,
          statusText: response.statusText,
          url: response.url,
          redirected: response.redirected,
          headers: [...response.headers].map(([name, value]) => ({
            name,
            value
          })),
          contentType: response.headers.get("content-type") ?? "",
          binary: false,
          size: 0,
          body: null,
          truncated: false
        };
        if (method !== "HEAD") await readBody(answer, response);
        return answer;
      } catch (error) {
        if (controller.signal.aborted)
          throw failing(
            `no whole response within ${timeoutMs / 1e3} s, so the request was aborted`,
            "timed_out"
          );
        throw failing(
          `the request failed: ${error}; a network error, or the server's CORS rules refuse a credentialed request from this page`
        );
      } finally {
        cancelLater(timer);
      }
    };
    let serve = (event) => {
      event.stopImmediatePropagation();
      let request;
      try {
        request = Object(parse(String(event.detail)));
      } catch {
        return;
      }
      let reply = (message) => dispatch(
        new Custom(fetchAnswerEvent, {
          detail: stringify({ id: String(request.id), ...message })
        })
      );
      reply({ accepted: true });
      sendFromPage(request).then(
        (answer) => reply({ answer }),
        (failure) => reply({
          failure: typeof failure?.code === "string" ? failure : failing(`page_fetch failed: ${failure}`)
        })
      );
    };
    function arm() {
      listen(takeEvent2, take, true);
      listen(pendingEvent, countPending, true);
      listen(fetchEvent, serve, true);
    }
    arm();
  }

  // src/main/index.ts
  installCapture(window);
  installNetworkCapture(window);
})();
