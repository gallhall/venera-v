# Import Comic

## Introduction

Venera supports importing comics from local files.
However, the comic files must be in a specific format.

## Restore Local Downloads

If you migrated the app and kept the local download folder but lost `local.db`,
you can restore the local database by scanning the current local path.

- Open `Local` -> `Import` -> `Restore local downloads`.
- The app scans the current local storage path and rebuilds entries.
- It does not copy files or add favorites.
- Duplicates (same title or directory) are skipped.

Make sure the local storage path in Settings points to the folder that contains
the downloaded comics before running this.

## Comic Directory

A directory considered as a comic directory only if it follows one of the following two types of structure:

**Without Chapter**

```
comic_directory
├── cover.[ext]
├── img1.[ext]
├── img2.[ext]
├── img3.[ext]
├── ...
```

**With Chapter**

```
comic_directory
├── cover.[ext]
├── chapter1
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── chapter2
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── ...
```

The file name can be anything, but the extension must be a valid image extension.

The page order is determined by the file name. App will sort the files by name and display them in that order.

Cover image is optional. 
If there is a file named `cover.[ext]` in the directory, it will be considered as the cover image.
Otherwise, the first image will be considered as the cover image.

The name of directory will be used as comic title. And the name of chapter directory will be used as chapter title.

## Archive

Venera supports importing comics from archive files.

The archive file must follow [Comic Book Archive](https://en.wikipedia.org/wiki/Comic_book_archive_file) format.

Currently, Venera supports the following archive formats:
- `.cbz`
- `.cb7`
- `.zip`
- `.7z`

## Video

Local videos can be imported and played with the video player, like
downloaded videos. Open `Local` -> `Import` and choose:

- `Video files`: pick one or more video files. Subtitles and a cover image
  can be picked together with them.
- `Video folder`: pick a folder. Its videos are imported, with the subtitles
  in it and in its subfolders (e.g. `Subs`).

Several videos become the episodes of one video, sorted by file name the way
people number them (`ep2` before `ep10`).

Supported files:
- Videos: `mp4`, `mkv`, `webm`, `avi`, `mov`, `m4v`, `flv`, `ts`, `m2ts`,
  `wmv`, `mpg`, `mpeg`, `3gp`, `rmvb`, `ogv`
- Subtitles: `srt`, `vtt`, `ass`, `ssa`, `sup`

A subtitle belongs to the video with the same name, optionally followed by a
tag such as a language: `ep1.srt`, `ep1.zh-CN.srt` and `ep1.简体.ass` all
belong to `ep1.mkv`. Before importing, the app lists the episodes and their
subtitles; `Add subtitles` picks more subtitle files, which are matched by
name, then by episode number (`Show - 03`, `S01E03`, `第3集`), or go to the
video if there is only one.

A cover is taken from an image named `cover`, `poster`, `folder`, `thumb`,
`fanart` or like the first video; otherwise a frame of the first episode is
used.

The files are copied to the local path, in the same layout as downloaded
videos. Embedded subtitles of the video files (e.g. in `mkv`) are kept and
can be switched in the player as well.
