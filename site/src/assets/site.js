// harnex.zyt.app: theme, copy buttons, docs menu, hero terminal, service worker.
(function () {
  "use strict";

  var root = document.documentElement;
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ── theme: auto → dark → light ──────────────────────────────────────
  var themeButton = document.querySelector("button.theme");
  function currentTheme() {
    try { return localStorage.getItem("harnex-theme") || "auto"; } catch (e) { return "auto"; }
  }
  function applyTheme(theme) {
    if (theme === "auto") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", theme);
    try {
      if (theme === "auto") localStorage.removeItem("harnex-theme");
      else localStorage.setItem("harnex-theme", theme);
    } catch (e) {}
    if (themeButton) {
      themeButton.textContent = "theme:" + theme;
      themeButton.setAttribute("aria-label", "Theme: " + theme + ". Change theme");
    }
  }
  if (themeButton) {
    applyTheme(currentTheme());
    themeButton.addEventListener("click", function () {
      var order = ["auto", "dark", "light"];
      applyTheme(order[(order.indexOf(currentTheme()) + 1) % order.length]);
    });
  }

  // ── copy buttons ────────────────────────────────────────────────────
  function copyText(text, button) {
    function done() {
      button.textContent = "copied";
      button.classList.add("done");
      setTimeout(function () { button.textContent = "copy"; button.classList.remove("done"); }, 1400);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () {});
    } else {
      var area = document.createElement("textarea");
      area.value = text;
      document.body.appendChild(area);
      area.select();
      try { document.execCommand("copy"); done(); } catch (e) {}
      area.remove();
    }
  }
  function addCopy(container, getText) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy";
    button.textContent = "copy";
    button.setAttribute("aria-label", "Copy to clipboard");
    button.addEventListener("click", function () { copyText(getText(), button); });
    container.appendChild(button);
  }
  document.querySelectorAll(".cmd").forEach(function (cmd) {
    var code = cmd.querySelector("code");
    if (code) addCopy(cmd, function () { return code.textContent; });
  });
  document.querySelectorAll(".codeblock").forEach(function (block) {
    var head = block.querySelector(".head");
    var pre = block.querySelector("pre");
    if (head && pre) addCopy(head, function () { return pre.textContent.replace(/\n$/, ""); });
  });

  // ── docs menu on small screens ──────────────────────────────────────
  var side = document.querySelector(".side");
  var toggle = document.querySelector(".side-toggle");
  if (side && toggle) {
    toggle.addEventListener("click", function () {
      var open = side.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  // ── hero terminal: type the command, then let the worker answer ─────
  var term = document.querySelector(".term pre[data-play]");
  if (term && !reduceMotion) {
    var lines = Array.prototype.slice.call(term.children);
    var command = lines.shift();
    var full = command.innerHTML;
    var promptNode = command.querySelector(".p");
    var typed = promptNode ? promptNode.outerHTML : "";
    var body = command.textContent.slice(promptNode ? promptNode.textContent.length : 0);
    lines.forEach(function (line) { line.hidden = true; });
    command.innerHTML = "";
    command.classList.add("typing");
    var i = 0;
    var started = false;
    function typeNext() {
      if (i <= body.length) {
        command.innerHTML = typed + '<span class="c">' + escapeHtml(body.slice(0, i)) + "</span>";
        i += 1;
        setTimeout(typeNext, i < 3 ? 160 : 16 + Math.random() * 26);
        return;
      }
      command.innerHTML = full;
      command.classList.remove("typing");
      // the worker takes a moment to reply
      setTimeout(function () { revealNext(0); }, 1500);
    }
    function revealNext(index) {
      if (index >= lines.length) return;
      var line = lines[index];
      line.hidden = false;
      var pause = Number(line.getAttribute("data-wait") || 110);
      setTimeout(function () { revealNext(index + 1); }, pause);
    }
    function start() {
      if (started) return;
      started = true;
      setTimeout(typeNext, 500);
    }
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (entries, observer) {
        if (entries.some(function (e) { return e.isIntersecting; })) { observer.disconnect(); start(); }
      }, { threshold: 0.35 }).observe(term);
    } else {
      start();
    }
  }
  function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // ── Holm analytics, for the app's admins only ───────────────────────
  var surfaces = globalThis.__HOLM_SURFACES__;
  var analytics = document.getElementById("analytics");
  if (analytics && surfaces && surfaces.analytics) {
    analytics.href = surfaces.analytics;
    analytics.hidden = false;
  }

  // ── installable shell ───────────────────────────────────────────────
  if ("serviceWorker" in navigator && location.protocol === "https:") {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("/sw.js").catch(function () {});
    });
  }
})();
