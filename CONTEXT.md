# Image Overlay

The image overlay context defines how two images are aligned for visual comparison and exported as one PNG.

## Language

**Bottom image**:
The fixed reference layer used as the alignment origin and the minimum extent of the exported image.
_Avoid_: Base image, background image

**Top image**:
The comparison layer placed above the bottom image.
_Avoid_: Second image, overlay

**Backing scale**:
The number of source pixels representing one screen point, such as `1x`, `2x`, `3x`, or Android density-bucket equivalents. Image alignment uses screen points rather than raw source pixels. The app detects common filename and phone-screenshot conventions and allows either layer's scale to be corrected manually.
_Avoid_: Image zoom, transform scale

**Top-image transform**:
The top image's position, scale, and opacity, applied identically in the preview and exported image.
_Avoid_: Preview zoom, view transform

**Output canvas**:
The rectangular union, measured in screen points, of the bottom image and the transformed top image. The bottom image defines the minimum bounds; moving or enlarging the top image can expand the canvas, and areas covered by neither image remain transparent. Export uses the higher source backing scale so point-based alignment does not discard source detail.
_Avoid_: Output bounds, bottom-image size, fixed canvas

**Preview viewport**:
The visible workspace through which the output canvas is inspected. Panning or zooming the viewport never changes the exported image.
_Avoid_: Output canvas, image transform

# TinyPNG

**Minimum compression size**:
The configured lower bound for source image file size. Images smaller than this bound are skipped by default. A per-image switch overrides this rule until the selection is cleared; changing the threshold preserves manual choices. The default is 0 KB.

**Upload limit**:
The TinyPNG single-file upper bound of 5 MB. Images above this bound are skipped regardless of the minimum compression size.

**Skipped image**:
An image excluded before upload by the size rules or its per-image switch. Both the pending/completed group and the skipped group sort by original file size, largest first; ties use natural relative-path order, then source path for stability. Switching an image back on returns it to its size-based position in the pending group. The 5 MB upload limit cannot be overridden. In output-folder mode its original bytes are preserved; in replacement mode the source remains unchanged.

**Reset compression result**:
Discard one completed result by restoring original bytes at its destination, then switch off compression and move it to the skipped group. Replacement mode restores the preserved source snapshot; output-folder mode replaces the result with an unchanged original. If restoration fails, keep the result state and report the error. Completed images keep their comparison action and are excluded from later compression runs until reset and manually enabled again.

## Shared Luban and WebP selection

All three tools share one selection state and transaction for input validation, adding roots, background scanning, Git eligibility, cancellation, state restoration, grouping, and size-based ordering. Their models only supply supported formats, item construction, tool-specific limits, summaries, and compression execution. Luban and WebP use the same two groups, threshold defaults, per-image overrides, comparison, and Reset actions as TinyPNG. Luban has no upload-size limit. Existing WebP sources stay skipped and cannot be enabled for conversion. A WebP conversion that does not reduce file size also joins the skipped group and can be enabled again manually.

**Git-only selection**:
Git ignore rules are mandatory in every selection mode, including ordinary scans and individual image inputs. Matching files are excluded even when already tracked by Git or manually enabled earlier; negation rules can explicitly include them again. Each image is checked against its own working tree, including nested ignore rules and repository exclusions. Non-repository images retain normal behavior. Starting any run rechecks ignore rules; an ordinary run only processes its previously displayed queue, without adding newly discovered files or earlier output copies. Ignore-check failures stop selection or processing rather than admitting unchecked files.

Directories named `build`, `tmp`, `DerivedData`, or `Packages` are always excluded, case-insensitively, in Git and ordinary modes. This covers nested directories, directly selected excluded directories, and images or subdirectories selected from inside them. Recursive scans do not descend into excluded directories. `Packages` contains third-party libraries downloaded at pinned tags; its contents must not be compressed, converted, or copied into output folders. System temporary locations hosting a selected project remain usable; that project's own `tmp` directories are excluded.

Image discovery and filtering run off the main actor. Native directory enumeration skips non-image metadata and excluded directory trees, with at most four workers for large trees; cancellation remains tied to the scanning task. Input-root path information is prepared once before publishing rows. `python3 scripts/benchmark_image_scan.py /path/to/project --max-seconds 5` measures the actual Debug-mode selection pipeline without changing input files; optional expected-count and path-hash arguments verify that faster scans preserve the result set.

All three tools offer an off-by-default filter for uncommitted images within the selected files or folders. It is available only when every selected path belongs to a Git working tree; without inputs or with any non-repository path it stays off and disabled. It includes staged, unstaged, and untracked files from Git status, excluding ignored, deleted, and symbolic-link files. Git deletion records are excluded even if the file remains on disk; a separate untracked record can include a recreated image. Enabling it forces original replacement and locks that switch; disabling it restores the user's manual replacement setting. Cancelling a filter rescan restores the mode associated with the retained list. Each added input rechecks all selected paths and rescans their images using the current options. If an added path invalidates Git eligibility, the filter turns off automatically and the normal image list returns. Starting a filtered run checks every original input again, including missing paths; if eligibility is lost, the run stops before processing without discarding those inputs. Git status failures report an error without falling back to processing the whole folder. Existing size limits and per-image choices still apply.

Reset preserves the original image format and extension. For a JPEG or WebP result in an output folder, restore an unchanged copy with the source extension, choose an unused name if needed, then remove the discarded result. For WebP replacement, restore the deleted source at its original path before removing the generated WebP. A recreated source with different bytes blocks Reset rather than being overwritten. Results retain their original replacement mode even when the page-wide switch changes later.

**Top-image hit area**:
The top image's displayed rectangular frame, including transparent pixels. A gesture that begins inside this area edits the top image; a gesture that begins elsewhere navigates the preview viewport.
_Avoid_: Opaque pixels, selected layer

# Watermark Removal

**Watermark candidate**:
A source-pixel rectangle obtained by mapping Vision OCR from an overlapping tile back to the original image. Vision boxes have a bottom-left origin; image crops and repair masks use a top-left origin. The watermark text is not fixed: repeated text fingerprints of any script — numbers, names, words — identify candidate families, and a candidate's strokes must be faint (a translucent overlay) rather than solid content text. A fingerprint identifies a family, not permission to erase every pixel in a rectangle.
_Avoid_: Manual selection, preview viewport, numeric-only fingerprint

**Local repair**:
The built-in processor builds a low-contrast stroke template by consensus from the repeated watermark instances: boxes are aligned on their stroke mass and only strokes recurring across them survive, so content bleeding into one recognized box can never define the repair. After matching, the template grows into adjacent strokes that repeat at every matched position and stay connected, which pulls watermark parts the OCR boxes missed (for example the name beside a repeated number) into the repair. It supports dark strokes on light backgrounds and light strokes on dark backgrounds by complementing RGB during light-stroke repair, while retaining OCR on the original image. It matches the template across the image; occluded or edge-clipped matches require both repeated spatial offsets and visible stroke evidence on the unoccluded part — saturated content covering a lattice-predicted position (photos, avatars) abstains instead of disproving the match. Within the stroke mask, agreeing unmasked neighbors provide the background; otherwise the processor reverses the shared translucent overlay. Source pixels outside the mask remain untouched. The repeated-template repair runs first; repairing only the recognized light-text boxes is a fallback. Processing is local, cancellable, automatic-only, and produces a new PNG without modifying the source file. Opaque occlusion and pre-JPEG image detail cannot be recovered exactly from a single image.
_Avoid_: AI inpainting, original replacement

# ID Photo

**Person mask**:
The local Vision person-segmentation mask preserves people, including clothing and soft hair edges. Non-person pixels are replaced with a solid red (default), blue, white, or light gray (#D9D9D9) background, or made transparent. All five outputs share one segmentation result and retain the orientation-corrected source dimensions. Transparent PNGs retain soft mask alpha; the preview checkerboard is not exported. This tool replaces backgrounds; it does not crop to a passport size or certify compliance with an issuing authority's photo rules. The source file remains unchanged.
