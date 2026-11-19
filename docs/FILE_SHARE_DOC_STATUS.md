# File Share Doc — source integration / validation record

Status: **Draft PR #6: source integrated, NOT fully implemented or device-validated**.

## Completed in this branch
- Toolbox shows **File Share Doc** separately from existing **File Share** LAN tool.
- Unified transfer cards route editable Word/Excel/PowerPoint/text formats to
  File Share Doc instead of routing DOCX through destructive text-to-PDF conversion.
- Browses Android and Windows local files, including providers that yield byte
  streams rather than readable paths.
- Creates a minimal, valid, local DOCX with standard OOXML relationships.
- Offline editable text fields for:
  - DOCX/DOCM/DOTX paragraphs plus header, footer and note part text.
  - XLSX/XLSM/XLTX cells (shared strings become independent inline strings;
    formula cells are intentionally protected, numeric cells retain numeric type).
  - PPTX/PPTM/PPSX/POTX slide text.
  - ODT/ODS/ODP paragraphs and text.
  - HTML/HTM, Markdown, TXT, CSV, JSON, XML, SVG and source/text formats as text.
- Basic DOCX whole-paragraph **Bold / Italic / Underline** controls stored in actual WordprocessingML runs. Mixed formatting within edited paragraphs may still change.
- Find/Replace, search, word count, non-destructive `_edited` copies, ZIP package
  re-encoding, basic ZIP integrity verification, Android public Downloads and
  Windows folder-picker export, LAN queue send to unified dashboard.
- **DOCX view**: Gander's exact vendored **docx-preview 0.4.1** and
  **JSZip 3.10.1** bytes are bundled as Flutter assets. An offline token-scoped
  loopback server feeds the document and the local JavaScript to Android WebView
  or Windows WebView2, avoiding WebView2's 2MB NavigateToString limit.
  All external origins blocked by CSP and WebView URL navigation policy;
  iframe creation sandboxed before document rendering.
- HTML and Markdown have a separate sanitized in-app preview using exact Gander-vendored `marked` and `DOMPurify` JavaScript (non-HTML resources and remote links blocked).
- Existing image editing and Android PDF tools are retained; ZIP/EPUB archive
  listing is built in; audio/video/legacy files may require an installed
  platform viewer.
- Gander, docx-preview, JSZip, marked and DOMPurify third-party licenses copied to
  `third_party/GANDER_VIEWER_LICENSES.md`.
- Source regression tests: `test/file_share_doc_engine_test.dart` for basic
  Word, Excel, PowerPoint, HTML, OpenDocument and file-copy preservation.

## Exact functionality boundaries (do not market as Word/WPS feature parity)
- Gander upstream is a file **viewer**, not a document editor.
- Gander's advanced `docx-pages.js`, `docx-lines.js` and native Kotlin
  bridge are **not** ported. The current document preview runs unmodified
  docx-preview and may differ from Gander/Word in pagination.
- The edit interface currently changes existing text containers only.
  It does **not** provide a complete Word ribbon, insert/delete paragraphs, advanced styles,
  complete header/footer formatting, comments, shapes, live spellcheck, tracked changes,
  robust WYSIWYG or multi-user editing.
- XLSX is a cell-text editor, **not** a formula engine, Excel-style grid,
  chart editor, pivot-table editor or complete sheet reflow.
- PPTX supports modifying slide text, **not** slide master/layout,
  animations, transitions or shape placement.
- Some original run-by-run mixed formatting may be altered when all text in a
  paragraph is replaced in one existing run. More elaborate DOCX fidelity
  needs a structural editor with full OOXML round-trip semantics.
- PDF editing continues to be Android-only by existing policy.
- Legacy .doc/.xls/.ppt, EPUB, ZIP, media and 3D formats are not all
  editable and some still open using an external viewer; not all Gander
  viewer formats have been ported.
- No claim is made that XML text editing reproduces Microsoft Office or WPS
  fidelity or that every arbitrary Office file will round-trip correctly.

## Required validation (none of the following has been executed)
1. Flutter toolchain: `flutter pub get`, `dart format`, `flutter analyze`.
2. `flutter test test/file_share_doc_engine_test.dart`.
3. Android debug build / Windows debug build **only when user authorizes builds**.
4. Android 8+ / current Android: filesystem picker, native WebView, localhost
   network-security policy, no remote requests, saved Downloads.
5. Windows 10/11: NuGet and WebView2 Runtime, writable custom WebView2
   profile, read-only installation directory, native folder selection.
6. Real DOCX/Excel/PPTX round-trip tests with tables, images, headers, charts,
   formulas, embedded links, styles, multi-lingual text and damaged files.
7. Fuzz/size/zip-bomb tests; Verify no data loss and no external network
   connections from malicious documents.

## References
- https://github.com/mokshablr/gander
- https://github.com/VolodymyrBaydalka/docxjs
- https://stuk.github.io/jszip/
- Gander's original full application is MIT; its vendored libraries retain
  their own licenses. The viewer is offline and takes only user-selected files.

**Never mark fully complete or ready to release until functionality and the
above checks have passed. No merge, deploy, workflow dispatch, APK/EXE build
or release has been performed for this change.**
