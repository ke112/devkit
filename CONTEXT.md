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
The configured lower bound for source image file size. Images smaller than this bound are skipped and are never uploaded to TinyPNG. The default is 100 KB.

**Upload limit**:
The TinyPNG single-file upper bound of 5 MB. Images above this bound are skipped regardless of the minimum compression size.

**Skipped image**:
An image excluded before upload because it is below the minimum compression size or above the upload limit. In output-folder mode its original bytes are preserved; in replacement mode the source remains unchanged.

**Top-image hit area**:
The top image's displayed rectangular frame, including transparent pixels. A gesture that begins inside this area edits the top image; a gesture that begins elsewhere navigates the preview viewport.
_Avoid_: Opaque pixels, selected layer

# Watermark Removal

**Watermark candidate**:
A source-pixel rectangle obtained by mapping Vision OCR from an overlapping tile back to the original image. Vision boxes have a bottom-left origin; image crops and repair masks use a top-left origin. Repeated numeric fingerprints identify candidate families, not permission to erase every pixel in a rectangle.
_Avoid_: Manual selection, preview viewport

**Local repair**:
The built-in processor learns a low-contrast stroke template from a repeated watermark on a uniform background. It matches that template across the image; occluded matches require both repeated spatial offsets and visible stroke evidence. Within the stroke mask, agreeing unmasked neighbors provide the background; otherwise the processor reverses the shared dark translucent overlay. Source pixels outside the mask remain untouched. Processing is local, cancellable, automatic-only, and produces a new PNG without modifying the source file. Opaque occlusion and pre-JPEG image detail cannot be recovered exactly from a single image.
_Avoid_: AI inpainting, original replacement
