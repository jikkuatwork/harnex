// Applies the saved theme before first paint (loaded in <head>).
(function () {
  var theme = null;
  try { theme = localStorage.getItem("harnex-theme"); } catch (e) {}
  if (theme === "dark" || theme === "light") document.documentElement.setAttribute("data-theme", theme);
})();
