# picsort

A tiny LAN-only web app for a group of people to score photos together.
Single-file [redbean](https://redbean.dev/) + [Fullmoon](https://github.com/pkulchenko/fullmoon)
binary you drop into a folder of pictures.

## Usage

```
./picsort.com           # serves the current directory on http://0.0.0.0:8080
```

On boot, picsort prints every LAN IPv4 it can detect; share one of those URLs.
Ratings are stored in `picsort.db` next to the binary.

- Pick a username on first visit (cookie-based, no password). Same name on
  another device = same user.
- Click a picture to open the lightbox. Keys: `1`-`5` rate (auto-advance),
  `0` mark-for-delete (auto-advance), `←`/`→` prev/next, `Esc` close.
- Hover the average to see each user's score.

Images are sorted by EXIF `DateTimeOriginal` (with file mtime as fallback).

## Build

```
./build.sh
```

Downloads redbean on first run, then zips `src/` into `picsort.com`.

## Source layout

```
src/.init.lua    -- routes, DB, scan
src/exif.lua     -- JPEG EXIF date parser
src/.lua/        -- libs visible to `require` (fullmoon, exif)
src/static/      -- app.css, app.js
```
