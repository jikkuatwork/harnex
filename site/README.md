# harnex.zyt.app

The harnex website: a static [Holm](https://holmhq.com) app built from the
repository's Markdown docs and the live CLI help, so the site and the gem
never drift.

```bash
ruby site/build.rb                              # docs + CLI help → site/app/web
holm app validate site/app --spec-v1
holm @zyt app deploy site/app --spec-v1 --host harnex.zyt.app --force
```

- `src/templates/`: ERB layout, home and doc pages.
- `src/assets/`: CSS, JS, and the feedback button (`feedback.js`, a copy of
  https://feedback.zyt.app/embed.js; project `6jyd3ya4`).
- `src/fonts/`: JetBrains Mono (SIL OFL 1.1, `OFL.txt`).
- `app/`: the deploy folder (`holm.json`, `holm.symbol.svg` from the MDI
  `console` icon (Apache-2.0), the identity set from
  `holm app identity generate`, and the built `web/`).

The build needs the `kramdown`, `kramdown-parser-gfm` and `rouge` gems; it is
dev tooling and is not shipped in the harnex gem.
