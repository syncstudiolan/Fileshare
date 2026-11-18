# Advanced PDF Editing Tools — Android-only draft implementation

## Status
The 24 upstream PDF tool entries have Android UI routes and local processing
implementations in this draft. **No Android compile, APK build, device test, or
GitHub Actions validation has been run for these changes**, per the request.
Functional parity, security guarantees, release size and device performance
therefore remain unverified. Do not merge or release before verification.

## App architecture
- One Toolbox card: **Advanced PDF Editing Tools**.
- Android: Flutter UI + native Kotlin PDFBox, OpenCV DNN/classical detector,
  Google ML Kit Latin OCR. Existing File Share LAN/Cloudflare/Auth/Cart logic
  is preserved.
- Windows/macOS: the Toolbox shows an Android-only dialog; the native
  PDFBox/Camera/DocAligner/ML Kit PDF code lives under Android sources only.
- UI follows File Share themes, not the upstream Compose design.
- Search at the top, Recent History beneath, category filters and tools.
- Local PDF history stores real copies of edited PDFs, timestamps, actions,
  rename and reopen options. No online upload by merely editing.

## Input and output rules
- Original input PDFs are not overwritten.
- Every successful operation writes a fresh local output.
- Open PDF, any stage -> **Add to Cart** asks Current Page, Choose another
  Page, or Entire PDF. Pending on-screen crop, redaction and Fill/Sign
  placements are rendered into a disposable PDF before Cart staging.
- A long-running operation never disables Cart; Cart uses the last fully
  persisted draft rather than writing partial bytes.
- Closed History entry -> Add to Cart adds complete PDF directly without
  a page-selection prompt.
- Cart copy is immutable: later rename, delete or additional edits do not
  change a previously queued attachment.
- Multi-output operations save all generated PDFs to History and show
  individual results with direct Cart choices.
- ZIP output goes directly to File Share staging.
- Scan/create and later History/Open Editor all support rename.
- Apply, Undo/Redo (session), Save, Share and Cart are independent actions.

## The 24 source tools
| Source tool | Android integration |
|---|---|
| Scan Document | ImagePicker camera/gallery, multi-shot reorder, OpenCV page corners, optional DocAligner, manual perspective, filters, ID/Book/Business Card layout, rename |
| PDF Workflow Builder | Ordered actions with configurable options and single/multi-output forwarding |
| Merge PDFs | Imported pages preserve inherited resources |
| Alternate & Mix PDF | Interleave pages, optional reverse of later scans |
| Compress PDF | JPEG stream recompression and progressive target-MB attempt |
| Split PDF | Each-page and custom-range multi-result |
| Split by Text | Text phrase starts a new part; OCR prerequisite for scans |
| Split by Bookmarks | Top-level bookmark sections |
| Split in Half | File halves or horizontal/vertical page slicing |
| Split by Size | Multi-part size target, with unavoidable oversized-page caveat |
| Organize Pages | Order selection, page deletion |
| Rotate PDF | 90/180/270, optional page ranges |
| Flip PDF | Vector-based page horizontal/vertical/both |
| Multiple Pages per Sheet | PDF Form XObjects, 2/4/6/9/16, optional divider lines |
| Crop & Resize | Normal crop with rotation coordinates or A4/A5/Letter/Legal |
| PDF to ZIP | ZIP of supplied PDFs |
| Fill & Sign | Text, imported image or drawn transparent PNG signature, page placement |
| Add Watermark | Diagonal watermark, size and transparency |
| Add Page Numbers | Left/center/right, N or Page N of Total |
| Redact PDF | Rasterize selected marked pages, rebuild document without hidden redacted text |
| OCR Scanned PDF | On-device Latin ML Kit OCR, invisible searchable text layer |
| Remove Password | Opens with supplied password and exports unlocked copy |
| Edit PDF Details | Title, author, subject and keywords |
| Set Password | PDFBox AES-256 encryption |

## Scanner model and APK size policy
The upstream DocAligner LC100 model is 4,757,043 bytes (Apache-2.0).
Android Gradle downloads the pinned upstream asset when an Android build is
performed, checks its exact size and packages it locally. The detector falls
back to OpenCV contours if the model cannot initialize. No runtime server
dependence is introduced for scanning. R8 minification and resource shrinking
are enabled, but actual release APK size remains **unmeasured**.

Reference: https://github.com/sammyZi/pdf-tools
See the MIT attribution in `third_party/PDF_TOOLS_ATTRIBUTION.md`.
DocAligner LC100 is identified by upstream as Apache-2.0.

## Release-blocking validation checklist (NOT YET EXECUTED)
1. Android Gradle and Flutter compilation, analyzer, widget tests.
2. Live camera and gallery, landscape and skewed documents, manual corner drag.
3. All 24 operations against known PDFs; page counts and saved output inspection.
4. Large PDFs and memory bounds, Unicode, encrypted and corrupt PDFs, rotated
   crop and page-number orientation, OCR and watermark geometry.
5. Multi-output ZIP, split/merge, workflow order, signature transparency and
   redaction recovery/security audit.
6. Open vs closed PDF Cart scope, pending edits, in-flight snapshot, history
   persistence and rename after app restart.
7. ARM64 release APK size analysis, R8 ML Kit/OpenCV native loading and UI
   performance/animation profiling.

This source branch remains a **draft** until those checks pass.
