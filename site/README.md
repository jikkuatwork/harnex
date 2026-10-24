# harnex.zyt.app

The harnex website: a static [Holm](https://holmhq.com) app built from the
repository's Markdown docs and the live CLI help, so the site and the gem
never drift.

```bash
ruby site/build.rb                              # docs + CLI help → site/app/web
holm app validate site/app --spec-v1
holm @zyt app deploy site/app --spec-v1 --host harnex.zyt.app --force
```

- `src/templates/`: ERB layout, home and doc pages, and `card.erb`, the social
  card.
- `src/assets/`: CSS, JS, the social card `og.png`, and the feedback button
  (`feedback.js`, a copy of https://feedback.zyt.app/embed.js; project
  `6jyd3ya4`).
- `src/fonts/`: JetBrains Mono (SIL OFL 1.1, `OFL.txt`).
- `app/`: the deploy folder (`holm.json`, `holm.symbol.svg`, the identity set
  from `holm app identity generate`, and the built `web/`).

The mark in `holm.symbol.svg` is a tmux layout: a prompt pane beside two
worker panes. Holm draws every icon and the manifest from it, in the
`iconStyle` and `themeColor` from `holm.json`. The link preview is a separate
1200x630 card: `site/card.rb` draws `src/assets/og.png` from `card.erb` with a
headless Chrome, and `layout.erb` names it in `og:image` and `twitter:image`,
which win over the `social_preview.png` Holm generates. After changing the
symbol, the style or the card:

```bash
holm app identity generate site/app
ruby site/card.rb                               # needs Chrome; see the script
ruby site/build.rb
```

The feedback form shows `app/web/icon-512.png` as its logo; upload it again
when the mark changes.

The build needs the `kramdown`, `kramdown-parser-gfm` and `rouge` gems; it is
dev tooling and is not shipped in the harnex gem.
