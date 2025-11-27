const ws = new WebSocket("ws://localhost:8080");

ws.onopen = () => {
  console.log("Browser connected!");
  ws.send("iam:browser");
};

ws.onmessage = async (e) => {
  const msg = e.data;
  console.log("COMMAND:", msg);

  // === EVAL ===
  if (msg.startsWith("eval ")) {
    try {
      ws.send("eval result: " + eval(msg.slice(5)));
    } catch (err) {
      ws.send("eval error: " + err);
    }
    return;
  }

  // === API ===
  if (msg.startsWith("api ")) {
    try {
      const { url, method, body } = JSON.parse(msg.slice(4));

      const res = await fetch(url, {
        method,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });

      const text = await res.text();
      ws.send("api result: " + text);
    } catch (err) {
      ws.send("api error: " + err.toString());
    }
    return;
  }

  // === FETCH (GET) ===
  if (msg.startsWith("fetch ")) {
    try {
      const url = msg.slice(6).trim();
      const res = await fetch(url);
      const text = await res.text();
      ws.send("fetch result: " + text);
    } catch (err) {
      ws.send("fetch error: " + err.toString());
    }
    return;
  }
};
