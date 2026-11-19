# File Share Doc — implementation and outstanding validation

**Repository:** `syncstudiolan/Fileshare`  
**Branch:** `draft/live-scanner-smooth-editor-tools`  
**Pull request:** Draft PR #6  
**Status:** Extensive source integration committed. Not fully MS Office/WPS compatible. Flutter/Android/Windows tests not run.

## Implemented: user-facing Toolbox / common UI
- Separate **File Share Doc** tool, leaving existing File Share LAN tool and Android PDF editor intact
- New Word DOCX, native file picker, SAF staging for non-path providers, names preserved from LAN/QR transfer cards
- Undoable source preservation by non-destructive Save Copy, Android public Downloads / Windows folder picker export
- Search, Find & Replace, word count, large-document text-field virtualization
- Integrated existing LAN queue for edited-document transfer; prevents sharing unsaved edits
- Existing Image Editor opened for photos and Android PDF tools remain Android-only
- Windows PDFs open read-only in embedded WebView2; no PDF editing on Windows

## Implemented: Word / Excel / PowerPoint text-level editing
- DOCX/DOCM/DOTX existing paragraph text, headers, footers, footnotes/endnotes where present
- **Bold, Italic, Underline** paragraph-level OOXML run properties
- **Alignment:** left/center/right/justified; **structure:** insert/delete paragraphs
- Insert true OOXML Word tables via specified row/column count; inserted table cells become selectable text blocks on re-open
- Word A4/Letter/Legal, portrait/landscape and page margins in twips; original layout is unchanged until settings are edited
- XLSX/XLSM/XLTX existing cell text and numeric values, independent shared string changes; original formula cells protected
- PPTX/PPTM/PPSX/POTX existing slide text; original package parts preserved in normal cases
- ODT/ODS/ODP text blocks and HTML/Markdown/TXT/CSV/JSON/XML/source files as text
- OOXML content is repackaged into a new ZIP-based document with simple entry-count validation; file byte sizes bounded

## Implemented: Gander's offline document-viewing engines (Android + Windows code)
- **Word:** original Gander `docx.html`, `docx.js`, `docx-pages.js`, `docx-lines.js`, night mode, search, `app.js`, `app.css`, `find.js`, docx-preview 0.4.1, JSZip 3.10.1
- **Spreadsheet:** Gander's SheetJS CE library, worksheet tabs, cell selection, text search; preview limited to 1,000 rows × 100 columns per sheet
- **PowerPoint:** Gander's PPTXjs, patched `gander-pptx.js`, supporting jQuery/JSZip2/D3/NVD3 libraries, original slide CSS
- **Legacy Word/OpenDocument:** Gander's `.doc/.odt/.rtf` JS readers, styles, layout and picture helpers
- **EPUB:** Gander's EPUB chapter/book engine and CSS address sanitizer, search
- **Markdown/HTML:** Gander's marked + DOMPurify with sanitized offline markup preview
- **ZIP:** nested entries browsed, opened in appropriate editor/viewer, added, renamed and deleted, saved as new ZIP
- **Windows PDF:** WebView2 native PDF renderer over localhost HTTP Range support
- Multimedia, some graphic formats, STL/3D and legacy .ppt still use OS viewers or specialized existing tools; **not fully ported from Gander**
- Server-bound files and JS are delivered through per-viewer random token-scoped loopback HTTP URLs (no document cloud upload)
- Android local cleartext network-security exception, WebView URL policies and CSP; vendored licenses in `third_party/GANDER_VIEWER_LICENSES.md`

## Explicitly not implemented or not claimed
This is **not yet** an MS Office/WPS-quality WYSIWYG editing suite. Missing:
- Word true on-page rich-text selection and editing, complete ribbon, fonts/sizes/colors, stable mixed-run fidelity, collaborative editing, complex drawing/object operations, advanced header/footer and tables, comments and tracked changes
- Excel formula creation/evaluation, sheet insertion/deletion, graphical workbook editor, pivot tables, charts and conditional-format authoring
- PowerPoint slide insertion/reorder, shape movement, transition/animation editor, slide masters and full embedded-media editing
- General editable audio/video/PDF/3D/ZIP contents, full legacy formats and feature parity for every Gander viewer type
- Full app/browser/OS-level QA, corpus-based OOXML compatibility, strict asset sandbox and security sign-off

The Gander repository is a VIEWER; porting Gander does not produce a complete Office-compatible editing engine. Even if all source tests pass, DOCX/XLSX/PPTX fidelity needs real cross-suite round-trip testing.

## Test/source validation status
- **Syntax-level source checks only:** original/adapted Gander JavaScript was syntax-parsed using V8; all tested modules parsed
- **Regression tests authored** in `test/file_share_doc_engine_test.dart` for creating Word, editing DOCX text/style/structure, inserting tables, Legal landscape layout, Excel shared-string/numeric/formula integrity, PPTX slide text, ODT text and source preservation
- These Dart/Flutter tests are **unrun**
- Flutter `pub get`, `flutter analyze`, `flutter test` **unrun**, because the source-editing environment lacks the Flutter/Dart SDK
- Android and Windows runtime, WebView2/plugin compatibility, real document round-trips and hardware tests **unrun at user's request to defer device tests**
- Builds, workflow dispatch, PR merge, deploy and releases **not performed**
- No 100%-complete or production-ready claim can be made until missing features are implemented and validation passes

## Third-party
- Gander: https://github.com/mokshablr/gander (MIT)
- docx-preview: https://github.com/VolodymyrBaydalka/docxjs (Apache-2.0)
- JSZip: https://stuk.github.io/jszip/ (MIT)
- SheetJS CE, PPTXjs, D3, marked, DOMPurify and others: licenses reproduced from Gander in `third_party/GANDER_VIEWER_LICENSES.md`
