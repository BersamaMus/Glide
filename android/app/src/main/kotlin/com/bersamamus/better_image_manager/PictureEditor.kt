package com.bersamamus.better_image_manager

import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * The editor on Android: where a picture's subject is (ML Kit), and saving
 * an edited copy of it into the gallery. The same steps, in the same order,
 * as on a PC (packages/native_imaging/src: look.cpp, subject.cpp, and
 * ni_edit in native_imaging.cpp), so what's saved is what the preview
 * showed: upright; adjusted and filtered; its background changed; turned,
 * flipped and cropped.
 */
class PictureEditor(private val resolver: ContentResolver, private val images: Uri) {

    // ---------------------------------------------------------------------
    // The subject
    // ---------------------------------------------------------------------

    /**
     * Where picture [id]'s subject is: upright, about 1024 pixels on its
     * longest side, a byte a pixel from 0 (background) to 255 (subject).
     */
    fun subjectMask(id: Long): Map<String, Any> {
        val picture = decode(ContentUris.withAppendedId(images, id), maxSide = 1024)
        val segmenter = SubjectSegmentation.getClient(
            SubjectSegmenterOptions.Builder().enableForegroundConfidenceMask().build()
        )
        try {
            val result = Tasks.await(segmenter.process(InputImage.fromBitmap(picture, 0)))
            val confidence = result.foregroundConfidenceMask
                ?: throw IllegalStateException("No subject found")
            val mask = ByteArray(picture.width * picture.height)
            confidence.rewind()
            for (i in mask.indices) mask[i] = (confidence.get().coerceIn(0f, 1f) * 255 + 0.5f).toInt().toByte()
            return mapOf("width" to picture.width, "height" to picture.height, "alpha" to mask)
        } finally {
            segmenter.close()
            picture.recycle()
        }
    }

    // ---------------------------------------------------------------------
    // Saving
    // ---------------------------------------------------------------------

    /** What ni_edit's look holds, in look.h's order. */
    private object Look {
        const val EXPOSURE = 0
        const val BRIGHTNESS = 1
        const val CONTRAST = 2
        const val HIGHLIGHTS = 3
        const val SHADOWS = 4
        const val VIGNETTE = 5
        const val SATURATION = 6
        const val WARMTH = 7
        const val TINT = 8
        const val MONO = 9
        const val FADE = 10
        const val SETTINGS = 11
    }

    /**
     * Saves an edited copy of picture [id] beside it (or, where the app may
     * not add pictures, in Pictures/Glide), keeping when,
     * where and with what it was taken. Answers the copy's id and path.
     *
     * [crop] is left, top, width and height as fractions of the turned
     * picture; [look] in look.h's order; [background] 0 none, 1 blur, 2
     * remove, 3 replace with [color] (0xRRGGBB), 4 black and white (colour
     * pop); [mask] as [subjectMask].
     */
    fun saveCopy(
        id: Long,
        quarterTurns: Int,
        flip: Boolean,
        crop: List<Double>,
        look: List<Double>,
        background: Int,
        color: Int,
        blurSpread: Double,
        mask: ByteArray?,
        maskWidth: Int,
        maskHeight: Int,
    ): Map<String, Any> {
        if (Build.VERSION.SDK_INT < 29) throw UnsupportedOperationException("Editing needs Android 10 or later")
        val source = ContentUris.withAppendedId(images, id)

        // Upright, at most about 24 MP (a 50 MP photo whole would take more
        // memory than a phone gives an app).
        var picture = decode(source, maxPixels = 24_000_000)
        val settings = FloatArray(Look.SETTINGS) { look.getOrNull(it)?.toFloat() ?: 0f }
        if (settings.any { it != 0f }) withLook(picture, settings)
        if (background != 0 && mask != null) withBackground(picture, background, color, blurSpread, mask, maskWidth, maskHeight)

        // Turned, flipped, then cropped.
        if (quarterTurns % 4 != 0 || flip) {
            val turn = Matrix().apply {
                postRotate(90f * (((quarterTurns % 4) + 4) % 4))
                if (flip) postScale(-1f, 1f)
            }
            picture = Bitmap.createBitmap(picture, 0, 0, picture.width, picture.height, turn, true).also { picture.recycle() }
        }
        val (left, top, width, height) = crop
        val x = min((left.coerceIn(0.0, 1.0) * picture.width + 0.5).toInt(), picture.width - 1)
        val y = min((top.coerceIn(0.0, 1.0) * picture.height + 0.5).toInt(), picture.height - 1)
        val w = ((width * picture.width + 0.5).toInt()).coerceIn(1, picture.width - x)
        val h = ((height * picture.height + 0.5).toInt()).coerceIn(1, picture.height - y)
        if (x != 0 || y != 0 || w != picture.width || h != picture.height) {
            picture = Bitmap.createBitmap(picture, x, y, w, h).also { picture.recycle() }
        }

        // A removed background stays see-through as a PNG; a PNG stays one.
        val original = describe(source)
        val png = background == 2 || original.mime == "image/png"
        val stem = original.name.substringBeforeLast('.')
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$stem (edited).${if (png) "png" else "jpg"}")
            put(MediaStore.Images.Media.MIME_TYPE, if (png) "image/png" else "image/jpeg")
            put(MediaStore.Images.Media.IS_PENDING, 1)
            if (original.taken > 0) put(MediaStore.Images.Media.DATE_TAKEN, original.taken)
        }
        val copy = insert(values, original.folder)
        try {
            resolver.openOutputStream(copy)!!.use {
                picture.compress(if (png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 92, it)
            }
            if (!png) copyMetadata(source, copy)
            resolver.update(copy, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(copy, null, null)
            throw e
        } finally {
            picture.recycle()
        }
        @Suppress("DEPRECATION")
        val path = resolver.query(copy, arrayOf(MediaStore.Images.Media.DATA), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: ""
        return mapOf("id" to ContentUris.parseId(copy), "path" to path)
    }

    /**
     * Saves a new picture the app made (a sticker, a collage) into the
     * gallery, in Pictures/Glide, from its [png] bytes, as
     * [name]. Answers its id and path.
     */
    fun saveNew(png: ByteArray, name: String): Map<String, Any> {
        if (Build.VERSION.SDK_INT < 29) throw UnsupportedOperationException("Saving needs Android 10 or later")
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.IS_PENDING, 1)
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Glide/")
        }
        val picture = resolver.insert(images, values) ?: throw IllegalStateException("Couldn't add the picture")
        try {
            resolver.openOutputStream(picture)!!.use { it.write(png) }
            resolver.update(picture, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(picture, null, null)
            throw e
        }
        @Suppress("DEPRECATION")
        val path = resolver.query(picture, arrayOf(MediaStore.Images.Media.DATA), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: ""
        return mapOf("id" to ContentUris.parseId(picture), "path" to path)
    }

    private data class Original(val name: String, val mime: String, val folder: String, val taken: Long)

    private fun describe(uri: Uri): Original {
        val columns = arrayOf(
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.DATE_TAKEN,
        )
        resolver.query(uri, columns, null, null, null)?.use {
            if (it.moveToFirst()) {
                return Original(
                    it.getString(0) ?: "picture.jpg",
                    it.getString(1) ?: "image/jpeg",
                    it.getString(2) ?: "Pictures/",
                    if (it.isNull(3)) 0L else it.getLong(3),
                )
            }
        }
        throw IllegalStateException("The picture's gone")
    }

    /**
     * A new picture in [folder]: where the original is, unless Android won't
     * let the app add pictures there (another app's own folder, as
     * WhatsApp's), then Pictures/Glide.
     */
    private fun insert(values: ContentValues, folder: String): Uri {
        values.put(MediaStore.Images.Media.RELATIVE_PATH, folder)
        try {
            resolver.insert(images, values)?.let { return it }
        } catch (_: IllegalArgumentException) {
            // Not a folder the app may add to.
        }
        values.put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Glide/")
        return resolver.insert(images, values) ?: throw IllegalStateException("Couldn't add the picture")
    }

    /** When, where and with what it was taken, from [from] into the JPEG at [to]; it's upright now. */
    private fun copyMetadata(from: Uri, to: Uri) {
        val original = try {
            resolver.openInputStream(MediaStore.setRequireOriginal(from))
        } catch (_: SecurityException) {
            resolver.openInputStream(from) // without where it was taken
        }?.use { ExifInterface(it) } ?: return
        resolver.openFileDescriptor(to, "rw")?.use { file ->
            val copy = ExifInterface(file.fileDescriptor)
            for (tag in listOf(
                ExifInterface.TAG_DATETIME_ORIGINAL, ExifInterface.TAG_DATETIME, "OffsetTimeOriginal",
                ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL, "LensModel",
                ExifInterface.TAG_F_NUMBER, ExifInterface.TAG_EXPOSURE_TIME, "ISOSpeedRatings",
                ExifInterface.TAG_FOCAL_LENGTH, ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
                ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF,
                ExifInterface.TAG_GPS_LONGITUDE, ExifInterface.TAG_GPS_LONGITUDE_REF,
                ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF,
            )) {
                original.getAttribute(tag)?.let { copy.setAttribute(tag, it) }
            }
            copy.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
            copy.saveAttributes()
        }
    }

    // ---------------------------------------------------------------------
    // Decoding
    // ---------------------------------------------------------------------

    /** The picture at [uri], upright and mutable, neither side over [maxSide] or not over [maxPixels]. */
    private fun decode(uri: Uri, maxSide: Int = Int.MAX_VALUE, maxPixels: Int = Int.MAX_VALUE): Bitmap {
        val source = ImageDecoder.createSource(resolver, uri)
        return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.isMutableRequired = true
            val (w, h) = info.size.width to info.size.height
            val scale = min(1.0, min(maxSide.toDouble() / max(w, h), sqrt(maxPixels.toDouble() / (w.toDouble() * h))))
            if (scale < 1) decoder.setTargetSize(max(1, (w * scale).roundToInt()), max(1, (h * scale).roundToInt()))
        }.let { if (it.config == Bitmap.Config.ARGB_8888) it else it.copy(Bitmap.Config.ARGB_8888, true) }
    }

    // ---------------------------------------------------------------------
    // The look (look.cpp)
    // ---------------------------------------------------------------------

    private fun luma(r: Float, g: Float, b: Float) = 0.2126f * r + 0.7152f * g + 0.0722f * b

    private fun smoothstep(edge0: Float, edge1: Float, x: Float): Float {
        val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
        return t * t * (3 - 2 * t)
    }

    private fun withLook(picture: Bitmap, s: FloatArray) {
        val w = picture.width
        val h = picture.height
        val gain = 2f.pow(s[Look.EXPOSURE] * 1.5f)
        val gamma = 2f.pow(-s[Look.BRIGHTNESS] * 0.8f)
        forEachRow(h) { y ->
            val row = IntArray(w)
            val c = FloatArray(3)
            picture.getPixels(row, 0, w, 0, y, w, 1)
            val v = (y + 0.5f) / h
            for (x in 0 until w) {
                val p = row[x]
                c[0] = ((p shr 16) and 0xFF) / 255f
                c[1] = ((p shr 8) and 0xFF) / 255f
                c[2] = (p and 0xFF) / 255f
                // (pow, the costliest step, skipped when brightness is 0.)
                for (i in 0..2) c[i] = if (gamma == 1f) max(c[i] * gain, 0f) else max(c[i] * gain, 0f).pow(gamma)

                var l = luma(c[0], c[1], c[2]).coerceIn(0f, 1f)
                val lift = 1 + s[Look.SHADOWS] * 0.6f * (1 - l) * (1 - l) + s[Look.HIGHLIGHTS] * 0.5f * l * l
                for (i in 0..2) c[i] *= lift

                for (i in 0..2) c[i] = (c[i] - 0.5f) * (1 + s[Look.CONTRAST] * 0.6f) + 0.5f

                l = luma(c[0], c[1], c[2])
                for (i in 0..2) {
                    c[i] = l + (c[i] - l) * (1 + s[Look.SATURATION])
                    c[i] = c[i] + (l - c[i]) * s[Look.MONO]
                }

                c[0] *= 1 + s[Look.WARMTH] * 0.15f
                c[2] *= 1 - s[Look.WARMTH] * 0.15f
                c[1] *= 1 - s[Look.TINT] * 0.12f

                for (i in 0..2) c[i] = s[Look.FADE] * 0.12f + c[i] * (1 - s[Look.FADE] * 0.22f)

                val du = (x + 0.5f) / w - 0.5f
                val dv = v - 0.5f
                val edge = if (s[Look.VIGNETTE] == 0f) 0f else smoothstep(0.35f, 1.1f, sqrt(du * du + dv * dv) * 1.41421356f)
                for (i in 0..2) {
                    c[i] = if (s[Look.VIGNETTE] >= 0) c[i] * (1 - s[Look.VIGNETTE] * 0.75f * edge)
                    else c[i] + (1 - c[i]) * (-s[Look.VIGNETTE] * 0.6f * edge)
                }
                row[x] = (p and 0xFF000000.toInt()) or
                    (byte(c[0]) shl 16) or (byte(c[1]) shl 8) or byte(c[2])
            }
            picture.setPixels(row, 0, w, 0, y, w, 1)
        }
    }

    private fun byte(value: Float) = (value.coerceIn(0f, 1f) * 255 + 0.5f).toInt()

    /** [row] for each of [count] rows, spread over the phone's cores: each row's its own. */
    private fun forEachRow(count: Int, row: (Int) -> Unit) =
        java.util.stream.IntStream.range(0, count).parallel().forEach { row(it) }

    // ---------------------------------------------------------------------
    // The background (subject.cpp)
    // ---------------------------------------------------------------------

    /** One channel of a (width by height) buffer, read between pixels. (Millions of times: nothing allocated.) */
    private fun sample(data: FloatArray, offset: Int, stride: Int, width: Int, height: Int, fx: Float, fy: Float): Float {
        val x = fx.coerceIn(0f, (width - 1).toFloat())
        val y = fy.coerceIn(0f, (height - 1).toFloat())
        val x0 = x.toInt()
        val y0 = y.toInt()
        val x1 = min(x0 + 1, width - 1)
        val y1 = min(y0 + 1, height - 1)
        val ax = x - x0
        val ay = y - y0
        val top = y0 * width
        val bottom = y1 * width
        val a = data[(top + x0) * stride + offset]
        val b = data[(top + x1) * stride + offset]
        val c = data[(bottom + x0) * stride + offset]
        val d = data[(bottom + x1) * stride + offset]
        return (a * (1 - ax) + b * ax) * (1 - ay) + (c * (1 - ax) + d * ax) * ay
    }

    /** Three box blurs of radius r over each of the channels, close to a Gaussian. */
    private fun blur(data: FloatArray, width: Int, height: Int, channels: Int, r: Int) {
        val line = FloatArray(max(width, height) * channels)
        fun pass(count: Int, length: Int, step: Int, next: Int) {
            for (i in 0 until count) {
                val start = i * next
                for (ch in 0 until channels) {
                    // A running sum along the line, its ends repeated past them.
                    val base = start + ch
                    var sum = 0f
                    for (j in -r..r) sum += data[base + j.coerceIn(0, length - 1) * step]
                    for (j in 0 until length) {
                        line[j * channels + ch] = sum / (2 * r + 1)
                        sum += data[base + min(j + r + 1, length - 1) * step] - data[base + max(j - r, 0) * step]
                    }
                }
                for (j in 0 until length) for (ch in 0 until channels) data[start + j * step + ch] = line[j * channels + ch]
            }
        }
        repeat(3) {
            pass(height, width, channels, width * channels) // rows
            pass(width, height, width * channels, channels) // columns
        }
    }

    private fun withBackground(
        picture: Bitmap,
        background: Int,
        color: Int,
        blurSpread: Double,
        mask: ByteArray,
        maskWidth: Int,
        maskHeight: Int,
    ) {
        val w = picture.width
        val h = picture.height
        val maskValues = FloatArray(mask.size) { (mask[it].toInt() and 0xFF) / 255f }
        val mx = maskWidth.toFloat() / w
        val my = maskHeight.toFloat() / h

        // For a blur: the background blurred small (its longest side 512),
        // by itself, so the subject's colours don't spread into it.
        var sw = 0
        var sh = 0
        var blurred = FloatArray(0) // r, g, b weighted by background; the weight; r, g, b plain
        if (background == 1) {
            val scale = min(1f, 512f / max(w, h))
            sw = max(1, (w * scale + 0.5f).toInt())
            sh = max(1, (h * scale + 0.5f).toInt())
            val small = Bitmap.createScaledBitmap(picture, sw, sh, true)
            val pixels = IntArray(sw * sh).also { small.getPixels(it, 0, sw, 0, 0, sw, sh) }
            if (small !== picture) small.recycle()
            blurred = FloatArray(sw * sh * 7)
            val smx = maskWidth.toFloat() / sw
            val smy = maskHeight.toFloat() / sh
            for (y in 0 until sh) for (x in 0 until sw) {
                val p = pixels[y * sw + x]
                val back = 1 - sample(maskValues, 0, 1, maskWidth, maskHeight, (x + 0.5f) * smx - 0.5f, (y + 0.5f) * smy - 0.5f)
                val o = (y * sw + x) * 7
                for (ch in 0..2) {
                    val value = ((p shr (16 - 8 * ch)) and 0xFF).toFloat()
                    blurred[o + ch] = value * back
                    blurred[o + 4 + ch] = value
                }
                blurred[o + 3] = back
            }
            val sigma = blurSpread.coerceIn(0.001, 0.1) * max(sw, sh)
            blur(blurred, sw, sh, 7, max(1, ((sqrt(1 + 4 * sigma * sigma) - 1) / 2).roundToInt()))
        }

        // A photo's decoded as opaque: made see-through before its alpha's set.
        if (background == 2) picture.setHasAlpha(true)
        val fill = floatArrayOf(((color shr 16) and 0xFF).toFloat(), ((color shr 8) and 0xFF).toFloat(), (color and 0xFF).toFloat())
        val bx = sw.toFloat() / w
        val by = sh.toFloat() / h
        forEachRow(h) { y ->
            val row = IntArray(w)
            val behind = FloatArray(3)
            picture.getPixels(row, 0, w, 0, y, w, 1)
            for (x in 0 until w) {
                val p = row[x]
                val subject = sample(maskValues, 0, 1, maskWidth, maskHeight, (x + 0.5f) * mx - 0.5f, (y + 0.5f) * my - 0.5f)
                if (background == 2) {
                    val alpha = (((p ushr 24) and 0xFF) * subject + 0.5f).toInt()
                    row[x] = (alpha shl 24) or (p and 0x00FFFFFF)
                    continue
                }
                if (background == 3) {
                    fill.copyInto(behind)
                } else if (background == 4) {
                    // Colour pop: the subject in colour, what's behind it in
                    // black and white (Rec. 709's weights, as the look's).
                    behind.fill(luma(((p shr 16) and 0xFF).toFloat(), ((p shr 8) and 0xFF).toFloat(), (p and 0xFF).toFloat()))
                } else {
                    val fx = (x + 0.5f) * bx - 0.5f
                    val fy = (y + 0.5f) * by - 0.5f
                    val weight = sample(blurred, 3, 7, sw, sh, fx, fy)
                    val trust = (weight * 10).coerceIn(0f, 1f)
                    for (ch in 0..2) {
                        val plain = sample(blurred, 4 + ch, 7, sw, sh, fx, fy)
                        val own = if (weight > 1e-3f) sample(blurred, ch, 7, sw, sh, fx, fy) / weight else plain
                        behind[ch] = own * trust + plain * (1 - trust)
                    }
                }
                val back = 1 - subject
                val r = (((p shr 16) and 0xFF) * subject + behind[0] * back).coerceIn(0f, 255f) + 0.5f
                val g = (((p shr 8) and 0xFF) * subject + behind[1] * back).coerceIn(0f, 255f) + 0.5f
                val b = ((p and 0xFF) * subject + behind[2] * back).coerceIn(0f, 255f) + 0.5f
                row[x] = 0xFF000000.toInt() or (r.toInt() shl 16) or (g.toInt() shl 8) or b.toInt()
            }
            picture.setPixels(row, 0, w, 0, y, w, 1)
        }
    }
}
