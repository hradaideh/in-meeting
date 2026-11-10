(() => {
  const ENDPOINT = "http://127.0.0.1:17384/mute";
  const host = location.hostname;
  const source = host.includes("meet.google")
    ? "meet"
    : host.includes("teams")
      ? "teams-web"
      : "web";

  let lastMuted = null;
  let lastActive = null;

  function post(body) {
    fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      mode: "cors",
      keepalive: true,
    }).catch(() => {
      /* live-tint not running */
    });
  }

  function readMeetMuted() {
    // Prefer the mic button's data-is-muted (locale-stable).
    const buttons = document.querySelectorAll("[data-is-muted]");
    for (const el of buttons) {
      const label = (el.getAttribute("aria-label") || "").toLowerCase();
      if (
        label.includes("microphone") ||
        label.includes("mic") ||
        label.includes("audio")
      ) {
        return el.getAttribute("data-is-muted") === "true";
      }
    }
    // Fallback: any data-is-muted in the call bar region.
    const any = document.querySelector("[data-is-muted]");
    if (any) return any.getAttribute("data-is-muted") === "true";
    return null;
  }

  function readTeamsMuted() {
    const candidates = [
      document.querySelector("#mic-button"),
      document.querySelector("[data-tid='toggle-mute']"),
      document.querySelector("[data-tid='microphone-button']"),
      ...document.querySelectorAll("button[aria-label]"),
    ].filter(Boolean);

    for (const el of candidates) {
      const label = (el.getAttribute("aria-label") || el.getAttribute("title") || "").toLowerCase();
      const tid = el.getAttribute("data-tid") || "";
      const looksMic =
        tid.includes("mute") ||
        tid.includes("microphone") ||
        label.includes("mute") ||
        label.includes("microphone") ||
        label.includes("mic");
      if (!looksMic && el.id !== "mic-button") continue;

      const cid = (el.getAttribute("data-cid") || "").toLowerCase();
      if (cid.includes("unmute") || label.includes("unmute")) return true;
      if (cid.includes("mute") && !cid.includes("unmute")) return false;

      const pressed = el.getAttribute("aria-pressed");
      if (pressed === "true") return false; // mic on
      if (pressed === "false") return true; // mic off / muted

      if (label.includes("unmute")) return true;
      if (label.includes("mute")) return false;
    }
    return null;
  }

  function tick() {
    const muted = source === "meet" ? readMeetMuted() : readTeamsMuted();
    const active = muted !== null;
    if (muted === lastMuted && active === lastActive) return;
    lastMuted = muted;
    lastActive = active;
    if (!active) {
      post({ active: false, source });
      return;
    }
    post({ active: true, muted, source });
  }

  const obs = new MutationObserver(() => tick());
  obs.observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["data-is-muted", "aria-pressed", "aria-label", "data-cid", "data-tid"],
  });
  setInterval(tick, 1000);
  tick();

  window.addEventListener("pagehide", () => {
    post({ active: false, source });
  });
})();
