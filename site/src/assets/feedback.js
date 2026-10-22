/*
 * The feedback button for any website. Add it with:
 *
 *   <script src="https://feedback.example.com/embed.js" data-project="abcd2345" async></script>
 *
 * The button reads its project's look (text, colour, side, style, the
 * panel's theme) as the page loads, so changes made in the app need no new
 * snippet. Attributes on the tag win over them: data-label="Feedback",
 * data-color="#c2410c", data-position="right" | "left",
 * data-button="pill" | "icon" | "none" (none: open the form from your own
 * control with window.HolmFeedback.open()), and data-theme="light" | "dark" |
 * "auto". A "holmfeedback:ready" event on window, and HolmFeedback.ready,
 * say the form is there.
 * Use data-origin="https://feedback.example.com" when this file is
 * copied into the site itself (Holm-hosted sites must, since their pages
 * only run their own scripts).
 *
 * The button and panel live in a shadow root, so the page's CSS and this
 * script's never mix. The form itself is an iframe on the feedback app's own
 * origin; it is sent the page's address without its query or fragment.
 */
(function () {
  var script = document.currentScript
  if (!script || window.HolmFeedback) return
  var data = script.dataset
  var origin
  try { origin = new URL(data.origin || script.src, location.href).origin } catch (error) { return }
  var project = data.project || ''
  // The app's own Design and Form tabs show this script on a mock page.
  var preview = data.preview != null && origin === location.origin
  if (!/^[a-z0-9]{8}$/.test(project) && !(preview && project === 'demo')) return

  var look = { label: 'Feedback', color: '#c2410c', position: 'right', button: 'pill', theme: 'light' }
  var pinned = {}
  if (data.label) pinned.label = data.label.slice(0, 24)
  if (/^#[0-9a-fA-F]{6}$/.test(data.color || '')) pinned.color = data.color
  if (data.position === 'left' || data.position === 'right') pinned.position = data.position
  if (/^(pill|icon|none)$/.test(data.button || '')) pinned.button = data.button
  if (/^(light|dark|auto)$/.test(data.theme || '')) pinned.theme = data.theme

  // White or ink, whichever reads better on the button's colour.
  function inkOn(hex) {
    var c = [1, 3, 5].map(function (i) {
      var v = parseInt(hex.slice(i, i + 2), 16) / 255
      return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    })
    var light = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    return 1.05 / (light + 0.05) >= (light + 0.05) / 0.06 ? '#ffffff' : '#1c1917'
  }
  var dark = window.matchMedia ? matchMedia('(prefers-color-scheme: dark)') : { matches: false }

  var host = document.createElement('div')
  host.style.cssText = 'all: initial; position: fixed; z-index: 2147483000;'
  var root = host.attachShadow({ mode: 'closed' })
  var spring = 'cubic-bezier(.16, 1, .3, 1)'
  root.innerHTML =
    '<style>' +
    ':host { all: initial; }' +
    '.wrap { --color: #c2410c; --ink: #fff; --sheet: #fff; font: 15px/1 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; -webkit-tap-highlight-color: transparent; }' +
    '.launcher { position: fixed; z-index: 3; bottom: 20px; right: 20px; display: inline-flex; align-items: center; gap: 9px; height: 48px; padding: 0 18px 0 14px; margin: 0;' +
    '  border: 0; border-radius: 999px; background: var(--color); color: var(--ink); font: 600 15px/1 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; letter-spacing: -0.01em; cursor: pointer;' +
    '  box-shadow: 0 1px 2px rgba(0,0,0,.16), 0 10px 26px -10px rgba(0,0,0,.45); opacity: 0; transform: translateY(16px) scale(.9); pointer-events: none;' +
    '  transition: opacity .35s, transform .55s cubic-bezier(.3, 1.35, .5, 1), box-shadow .25s, padding .35s ' + spring + ', gap .35s ' + spring + ', background-color .3s, color .3s; }' +
    '.ready .launcher { opacity: 1; transform: none; pointer-events: auto; }' +
    '.ready .launcher:hover { transform: translateY(-2px); box-shadow: 0 2px 4px rgba(0,0,0,.16), 0 16px 34px -12px rgba(0,0,0,.5); }' +
    '.ready .launcher:active { transform: scale(.96); transition-duration: .1s; }' +
    '.launcher:focus-visible { outline: 3px solid var(--color); outline-offset: 3px; }' +
    '.left .launcher { right: auto; left: 20px; }' +
    '.icons { position: relative; flex: none; width: 20px; height: 20px; }' +
    '.icons svg { position: absolute; inset: 0; width: 100%; height: 100%; transition: transform .45s cubic-bezier(.3, 1.4, .5, 1), opacity .2s; }' +
    '.mark { fill: currentColor; }' +
    '.x { fill: none; stroke: currentColor; stroke-width: 2.4; stroke-linecap: round; opacity: 0; transform: rotate(-90deg) scale(.5); }' +
    '.launcher:hover .mark { transform: rotate(-10deg) scale(1.08); }' +
    '.label { display: block; max-width: 240px; overflow: hidden; white-space: nowrap; transition: max-width .4s ' + spring + ', opacity .25s; }' +
    '.open .launcher { padding: 0 14px; gap: 0; }' +
    '.open .label { max-width: 0; opacity: 0; }' +
    '.open .mark, .open .launcher:hover .mark { opacity: 0; transform: rotate(90deg) scale(.5); }' +
    '.open .x { opacity: 1; transform: none; }' +
    '.icon .launcher { width: 56px; height: 56px; padding: 0; justify-content: center; gap: 0; }' +
    '.icon .icons { width: 26px; height: 26px; }' +
    '.icon .label { display: none; }' +
    '.none .launcher { display: none; }' +
    '.panel { position: fixed; z-index: 2; bottom: 84px; right: 20px; width: 384px; height: var(--h, 540px); max-height: calc(100vh - 108px);' +
    '  border-radius: 20px; overflow: hidden; background: var(--sheet); color-scheme: normal;' +
    '  box-shadow: 0 0 0 1px rgba(0,0,0,.06), 0 4px 12px rgba(0,0,0,.08), 0 30px 70px -22px rgba(0,0,0,.5);' +
    '  opacity: 0; visibility: hidden; transform: translateY(14px) scale(.95); transform-origin: bottom right;' +
    '  transition: opacity .16s ease-in, transform .2s ease-in, visibility 0s .2s, height .35s ' + spring + '; }' +
    '.left .panel { right: auto; left: 20px; transform-origin: bottom left; }' +
    '.icon .panel { bottom: 92px; }' +
    '.none .panel { bottom: 20px; }' +
    '.open .panel { opacity: 1; visibility: visible; transform: none; transition: opacity .22s ease-out, transform .5s ' + spring + ', visibility 0s, height .35s ' + spring + '; }' +
    '.panel iframe { display: block; width: 100%; height: 100%; border: 0; opacity: 0; transition: opacity .3s; }' +
    '.loaded .panel iframe { opacity: 1; }' +
    '.spinner { position: absolute; top: 50%; left: 50%; width: 22px; height: 22px; margin: -11px 0 0 -11px; box-sizing: border-box;' +
    '  border: 2px solid rgba(128,128,128,.25); border-top-color: var(--color); border-radius: 50%; animation: spin .8s linear infinite; }' +
    '.loaded .spinner { display: none; }' +
    '.scrim { display: none; }' +
    '@keyframes spin { to { transform: rotate(360deg); } }' +
    // On a phone the panel is a sheet from the bottom, over a dimmed page.
    '@media (max-width: 440px) {' +
    '  .wrap .panel { left: 0; right: 0; bottom: 0; width: auto; height: min(var(--h, 540px), 92vh); max-height: 92vh;' +
    '    border-radius: 22px 22px 0 0; opacity: 1; transform: translateY(102%); transition: transform .28s ease-in, visibility 0s .28s, height .35s ' + spring + '; }' +
    '  .wrap.open .panel { transform: none; transition: transform .5s ' + spring + ', visibility 0s, height .35s ' + spring + '; }' +
    '  .scrim { display: block; position: fixed; z-index: 1; inset: 0; background: rgba(12, 10, 18, .45); opacity: 0; visibility: hidden; transition: opacity .25s, visibility 0s .25s; }' +
    '  .open .scrim { opacity: 1; visibility: visible; transition: opacity .35s, visibility 0s; }' +
    '  .wrap.open .launcher { opacity: 0; transform: scale(.8); pointer-events: none; }' +
    '}' +
    '@media (prefers-reduced-motion: reduce) {' +
    '  .launcher, .panel, .open .panel, .scrim, .icons svg, .label { transition-property: opacity, visibility !important; }' +
    '  .launcher, .ready .launcher:hover, .panel, .open .panel, .icons svg { transform: none !important; }' +
    '}' +
    '</style>'

  var wrap = document.createElement('div')
  var scrim = document.createElement('div')
  scrim.className = 'scrim'
  var panel = document.createElement('div')
  panel.className = 'panel'
  panel.setAttribute('role', 'dialog')
  var spinner = document.createElement('div')
  spinner.className = 'spinner'
  var frame = document.createElement('iframe')
  frame.setAttribute('allow', 'clipboard-write')
  panel.appendChild(spinner)
  panel.appendChild(frame)
  var button = document.createElement('button')
  button.type = 'button'
  button.className = 'launcher'
  button.setAttribute('aria-expanded', 'false')
  // The app's own mark, a smiling speech bubble, turns into a close cross.
  button.innerHTML = '<span class="icons" aria-hidden="true"><svg class="mark" viewBox="0 0 24 24"><path d="M12 0C5.38 0 0 5.38 0 12C0 13.95 0.48 15.89 1.41 17.62L0.03 22.74C-0.06 23.09 0.04 23.45 0.29 23.71C0.55 23.96 0.91 24.06 1.26 23.97L6.38 22.59C8.11 23.51 10.05 24 12 24C15.31 24 18.31 22.65 20.48 20.48C22.65 18.31 24 15.31 24 12C24 5.38 18.62 0 12 0ZM12 22C6.48 22 2 17.52 2 12C2 6.48 6.48 2 12 2C17.52 2 22 6.48 22 12C22 17.52 17.52 22 12 22ZM8.5 10C8.5 10.55 8.05 11 7.5 11C6.95 11 6.5 10.55 6.5 10C6.5 9.45 6.95 9 7.5 9C8.05 9 8.5 9.45 8.5 10ZM14.61 13.2C15.05 13.54 15.13 14.17 14.8 14.61C14.12 15.49 13.1 16 12 16C10.9 16 9.88 15.49 9.2 14.61C8.87 14.17 8.96 13.54 9.4 13.2C9.83 12.87 10.46 12.96 10.8 13.4C11.38 14.16 12.62 14.16 13.21 13.4C13.54 12.96 14.16 12.87 14.61 13.2ZM17.5 10C17.5 10.55 17.05 11 16.5 11C15.95 11 15.5 10.55 15.5 10C15.5 9.45 15.95 9 16.5 9C17.05 9 17.5 9.45 17.5 10Z"/></svg>' +
    '<svg class="x" viewBox="0 0 24 24"><path d="M6 6l12 12M18 6 6 18"/></svg></span><span class="label"></span>'
  var label = button.querySelector('.label')
  wrap.appendChild(scrim)
  wrap.appendChild(panel)
  wrap.appendChild(button)
  root.appendChild(wrap)

  var open = false
  var loaded = false
  var override = null

  function paint() {
    var color = look.color
    wrap.className = 'wrap ' + look.position + ' ' + look.button + (open ? ' open' : '') + (loaded ? ' loaded' : '') + (shown ? ' ready' : '')
    wrap.style.setProperty('--color', color)
    wrap.style.setProperty('--ink', inkOn(color))
    wrap.style.setProperty('--sheet', look.theme === 'dark' || (look.theme === 'auto' && dark.matches) ? '#1c1a24' : '#ffffff')
    label.textContent = look.label
    button.setAttribute('aria-label', look.label)
    panel.setAttribute('aria-label', look.label)
    frame.title = look.label
  }
  function apply(settings) {
    for (var key in look) if (settings && settings[key] != null && pinned[key] == null) look[key] = settings[key]
    for (var pin in pinned) look[pin] = pinned[pin]
    paint()
  }
  var shown = false
  // Sites that open the form from their own link can wait for this event.
  function reveal() {
    if (shown) return
    shown = true
    paint()
    if (window.HolmFeedback) window.HolmFeedback.ready = true
    try { window.dispatchEvent(new Event('holmfeedback:ready')) } catch (error) {}
  }

  function page() {
    return origin + '/widget.html?p=' + project +
      '&url=' + encodeURIComponent(location.origin + location.pathname) +
      '&title=' + encodeURIComponent(document.title.slice(0, 200)) +
      '&viewport=' + innerWidth + 'x' + innerHeight + '&host=2' + (preview ? '&preview=1' : '')
  }
  function tell(message) {
    if (!loaded || !frame.contentWindow) return
    message.source = 'holm-feedback-host'
    frame.contentWindow.postMessage(message, origin)
  }
  // The form starts loading as a pointer comes near the button, so it's
  // there the moment it's opened.
  function load() { if (!frame.src) frame.src = page() }
  function show() {
    load()
    open = true
    paint()
    button.setAttribute('aria-expanded', 'true')
    tell({ type: 'open' })
    frame.focus()
  }
  function hide() {
    open = false
    paint()
    button.setAttribute('aria-expanded', 'false')
    if (look.button !== 'none') button.focus({ preventScroll: true })
  }
  button.addEventListener('pointerenter', load)
  button.addEventListener('focus', load)
  button.addEventListener('click', function () { open ? hide() : show() })
  scrim.addEventListener('click', hide)
  document.addEventListener('keydown', function (event) { if (open && event.key === 'Escape') hide() })
  if (dark.addEventListener) dark.addEventListener('change', paint)
  window.addEventListener('message', function (event) {
    var message = event.data
    if (!message) return
    // Unsaved settings from the app's Design and Form tabs, in a preview.
    if (preview && event.origin === location.origin && message.source === 'feedback-setup') {
      override = message.config || {}
      apply(override)
      if (loaded) frame.contentWindow.postMessage(message, origin)
      return
    }
    if (event.origin !== origin || event.source !== frame.contentWindow || message.source !== 'holm-feedback') return
    if (message.type === 'close') hide()
    if (message.type === 'size' && message.height > 0) panel.style.setProperty('--h', Math.min(Math.max(message.height, 280), 900) + 'px')
    if (message.type === 'ready') {
      loaded = true
      paint()
      if (override) frame.contentWindow.postMessage({ source: 'feedback-setup', config: override }, origin)
      if (open) tell({ type: 'open' })
    }
  })

  window.HolmFeedback = { open: show, close: hide, toggle: function () { open ? hide() : show() } }
  apply({})
  ;(document.body || document.documentElement).appendChild(host)

  if (preview) {
    // A preview opens at once and says it's ready for settings.
    reveal()
    if (data.open !== 'false') show()
    if (parent !== window) parent.postMessage({ source: 'holm-feedback', type: 'preview-ready' }, origin)
    return
  }
  // The project's look, then the button eases in; without an answer in a
  // couple of seconds it shows as the tag says.
  var waited = setTimeout(reveal, 2500)
  var url = origin + '/api/embed/' + project + '?from=' + encodeURIComponent(location.origin)
  if (!window.fetch) return reveal()
  fetch(url, { credentials: 'omit' }).then(function (response) {
    if (response.status === 404) throw new Error('missing')
    return response.json()
  }).then(function (reply) {
    if (reply && reply.project) apply(reply.project)
    clearTimeout(waited)
    reveal()
  }).catch(function (error) {
    clearTimeout(waited)
    // A project that doesn't exist shows no button at all.
    if (error && error.message === 'missing') { host.remove(); delete window.HolmFeedback; return }
    reveal()
  })
})()
