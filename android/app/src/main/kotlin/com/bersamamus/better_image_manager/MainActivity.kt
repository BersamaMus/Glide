package com.bersamamus.better_image_manager

import android.Manifest
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * The phone's own pictures, for the app on Android: every one in the
 * gallery (MediaStore), the thumbnails Android keeps of them, and what their
 * metadata says. See lib/services/gallery.dart.
 */
class MainActivity : FlutterActivity() {
    // Thumbnails are a few milliseconds each from Android's cache: a few at
    // once keeps the grid filling while it scrolls.
    private val work = Executors.newFixedThreadPool(4)
    private val main = Handler(Looper.getMainLooper())
    private var askingForAccess: MethodChannel.Result? = null
    private val editor by lazy { PictureEditor(contentResolver, images) }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "better_image_manager/gallery").setMethodCallHandler { call, result ->
            when (call.method) {
                "access" -> result.success(access())
                "askForAccess" -> askForAccess(result)
                "openSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
                    )
                    result.success(null)
                }
                "list" -> inBackground(result) { list() }
                "thumbnail" -> inBackground(result) {
                    thumbnail(call.argument<Number>("id")!!.toLong(), call.argument<Int>("size")!!)
                }
                "details" -> inBackground(result) { details(call.argument<Number>("id")!!.toLong()) }
                "share" -> {
                    share(ids(call.argument<List<Number>>("ids")!!))
                    result.success(null)
                }
                "trash" -> trash(ids(call.argument<List<Number>>("ids")!!), result)
                "subjectMask" -> inBackground(result) { editor.subjectMask(call.argument<Number>("id")!!.toLong()) }
                "saveEditedCopy" -> inBackground(result) {
                    editor.saveCopy(
                        id = call.argument<Number>("id")!!.toLong(),
                        quarterTurns = call.argument<Int>("quarterTurns")!!,
                        flip = call.argument<Boolean>("flip")!!,
                        crop = call.argument<List<Double>>("crop")!!,
                        look = call.argument<List<Double>>("look")!!,
                        background = call.argument<Int>("background")!!,
                        color = call.argument<Int>("color")!!,
                        blurSpread = call.argument<Double>("blurSpread")!!,
                        mask = call.argument<ByteArray>("mask"),
                        maskWidth = call.argument<Int>("maskWidth") ?: 0,
                        maskHeight = call.argument<Int>("maskHeight") ?: 0,
                    )
                }
                "saveNew" -> inBackground(result) {
                    editor.saveNew(call.argument<ByteArray>("png")!!, call.argument<String>("name")!!)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        work.shutdownNow()
        super.onDestroy()
    }

    /** Runs [task] off the main thread, answering with what it returns (or its error) on it. */
    private fun inBackground(result: MethodChannel.Result, task: () -> Any?) {
        work.execute {
            try {
                val value = task()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error(e.javaClass.simpleName, e.message, null) }
            }
        }
    }

    // ---------------------------------------------------------------------
    // Access
    // ---------------------------------------------------------------------

    /** What the pictures need to be read: Android 13 has its own permission for them. */
    private val readPermission: String
        get() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES
        else Manifest.permission.READ_EXTERNAL_STORAGE

    /** On Android 14, access to only the pictures the user picked. */
    private val someVisualPermission = "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"

    private fun granted(permission: String) = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /**
     * "all", "some" (only those the user picked, on Android 14), "none", or
     * "blocked": none, and Android won't ask again (only Settings can give it).
     */
    private fun access(): String = when {
        granted(readPermission) -> "all"
        Build.VERSION.SDK_INT >= 34 && granted(someVisualPermission) -> "some"
        askedBefore && !shouldShowRequestPermissionRationale(readPermission) -> "blocked"
        else -> "none"
    }

    private val askedBefore: Boolean
        get() = getPreferences(MODE_PRIVATE).getBoolean("askedForAccess", false)

    private fun askForAccess(result: MethodChannel.Result) {
        if (askingForAccess != null) {
            result.error("Busy", "Already asking", null)
            return
        }
        askingForAccess = result
        getPreferences(MODE_PRIVATE).edit().putBoolean("askedForAccess", true).apply()
        val permissions = mutableListOf(readPermission)
        if (Build.VERSION.SDK_INT >= 34) permissions += someVisualPermission
        // Where pictures were taken: hidden from apps without it.
        if (Build.VERSION.SDK_INT >= 29) permissions += Manifest.permission.ACCESS_MEDIA_LOCATION
        requestPermissions(permissions.toTypedArray(), ACCESS_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != ACCESS_REQUEST) return
        askingForAccess?.success(access())
        askingForAccess = null
    }

    // ---------------------------------------------------------------------
    // The gallery
    // ---------------------------------------------------------------------

    private val images: Uri
        get() = if (Build.VERSION.SDK_INT >= 29) MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        else MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    /**
     * Every picture in the gallery, as lists side by side (one entry a
     * picture): its id, path, size in bytes, when it was taken and last
     * changed (ms since 1970; 0 if unknown), and its width and height upright.
     */
    @Suppress("DEPRECATION") // DATA: still the file's path, readable with the media permission.
    private fun list(): Map<String, Any> {
        val ids = ArrayList<Long>()
        val paths = ArrayList<String>()
        val sizes = ArrayList<Long>()
        val taken = ArrayList<Long>()
        val modified = ArrayList<Long>()
        val widths = ArrayList<Int>()
        val heights = ArrayList<Int>()
        val columns = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATA,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.DATE_MODIFIED,
            MediaStore.Images.Media.WIDTH,
            MediaStore.Images.Media.HEIGHT,
            MediaStore.Images.Media.ORIENTATION,
        )
        contentResolver.query(images, columns, null, null, null)?.use { cursor ->
            val id = cursor.getColumnIndexOrThrow(columns[0])
            val path = cursor.getColumnIndexOrThrow(columns[1])
            val size = cursor.getColumnIndexOrThrow(columns[2])
            val dateTaken = cursor.getColumnIndexOrThrow(columns[3])
            val dateModified = cursor.getColumnIndexOrThrow(columns[4])
            val width = cursor.getColumnIndexOrThrow(columns[5])
            val height = cursor.getColumnIndexOrThrow(columns[6])
            val orientation = cursor.getColumnIndexOrThrow(columns[7])
            while (cursor.moveToNext()) {
                val file = cursor.getString(path) ?: continue
                ids += cursor.getLong(id)
                paths += file
                sizes += cursor.getLong(size)
                taken += if (cursor.isNull(dateTaken)) 0L else cursor.getLong(dateTaken)
                modified += cursor.getLong(dateModified) * 1000 // seconds, there
                // Turned on its side: its width and height as shown.
                val sideways = cursor.getInt(orientation) % 180 != 0
                widths += if (sideways) cursor.getInt(height) else cursor.getInt(width)
                heights += if (sideways) cursor.getInt(width) else cursor.getInt(height)
            }
        }
        return mapOf(
            "ids" to ids.toLongArray(),
            "paths" to paths,
            "sizes" to sizes.toLongArray(),
            "taken" to taken.toLongArray(),
            "modified" to modified.toLongArray(),
            "widths" to widths.toIntArray(),
            "heights" to heights.toIntArray(),
        )
    }

    /**
     * The thumbnail Android keeps of picture [id], neither side over [size],
     * upright: its width, height and RGBA pixels.
     */
    @Suppress("DEPRECATION") // Thumbnails.getThumbnail: before Android 10, the only way.
    private fun thumbnail(id: Long, size: Int): Map<String, Any> {
        val uri = ContentUris.withAppendedId(images, id)
        var bitmap = if (Build.VERSION.SDK_INT >= 29) {
            contentResolver.loadThumbnail(uri, Size(size, size), null)
        } else {
            MediaStore.Images.Thumbnails.getThumbnail(contentResolver, id, MediaStore.Images.Thumbnails.MINI_KIND, null)
                ?: throw IllegalStateException("No thumbnail")
        }
        if (bitmap.config != Bitmap.Config.ARGB_8888) bitmap = bitmap.copy(Bitmap.Config.ARGB_8888, false)
        val pixels = ByteBuffer.allocate(bitmap.byteCount)
        bitmap.copyPixelsToBuffer(pixels) // RGBA, byte by byte
        return mapOf("width" to bitmap.width, "height" to bitmap.height, "pixels" to pixels.array())
    }

    /**
     * What picture [id]'s metadata says: camera, settings and where it was
     * taken (with ACCESS_MEDIA_LOCATION; Android hides it otherwise).
     */
    private fun details(id: Long): Map<String, Any?> {
        var uri = ContentUris.withAppendedId(images, id)
        if (Build.VERSION.SDK_INT >= 29 && granted(Manifest.permission.ACCESS_MEDIA_LOCATION)) {
            uri = MediaStore.setRequireOriginal(uri)
        }
        val exif = contentResolver.openInputStream(uri)?.use { ExifInterface(it) } ?: return emptyMap()
        fun number(tag: String) = exif.getAttributeDouble(tag, Double.NaN).takeIf { !it.isNaN() && it > 0 }
        fun text(tag: String) = exif.getAttribute(tag)?.trim()?.takeIf { it.isNotEmpty() }
        val place = FloatArray(2)
        val located = exif.getLatLong(place) && (place[0] != 0f || place[1] != 0f)
        return mapOf(
            "make" to text(ExifInterface.TAG_MAKE),
            "model" to text(ExifInterface.TAG_MODEL),
            // EXIF's own names: Android's ExifInterface reads them, though
            // it has no constants for them.
            "lens" to text("LensModel"),
            "fnumber" to number(ExifInterface.TAG_F_NUMBER),
            "exposure" to number(ExifInterface.TAG_EXPOSURE_TIME),
            "iso" to number("ISOSpeedRatings"),
            "focal" to number(ExifInterface.TAG_FOCAL_LENGTH),
            "focal35" to number(ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM),
            "latitude" to if (located) place[0].toDouble() else null,
            "longitude" to if (located) place[1].toDouble() else null,
        )
    }

    // ---------------------------------------------------------------------
    // Sharing and deleting
    // ---------------------------------------------------------------------

    private fun ids(numbers: List<Number>) = numbers.map { ContentUris.withAppendedId(images, it.toLong()) }

    /** Android's share sheet, with the pictures at [uris] for the app chosen to read. */
    private fun share(uris: List<Uri>) {
        if (uris.isEmpty()) return
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
        }
        intent.type = "image/*"
        // Read access for whichever app it goes to, granted through ClipData.
        intent.clipData = android.content.ClipData.newRawUri(null, uris[0]).apply {
            uris.drop(1).forEach { addItem(android.content.ClipData.Item(it)) }
        }
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(Intent.createChooser(intent, null))
    }

    private var trashing: MethodChannel.Result? = null

    /**
     * Moves the pictures at [uris] to Android's trash, where they stay 30
     * days before going for good: Android asks the user first. Answers true
     * if they were, false if the user said no.
     */
    private fun trash(uris: List<Uri>, result: MethodChannel.Result) {
        if (trashing != null) {
            result.error("Busy", "Already deleting", null)
            return
        }
        if (Build.VERSION.SDK_INT >= 30) {
            trashing = result
            val request = MediaStore.createTrashRequest(contentResolver, uris, true)
            startIntentSenderForResult(request.intentSender, TRASH_REQUEST, null, 0, 0, 0)
        } else {
            // No trash before Android 11: deleted, as its own gallery did.
            inBackground(result) {
                uris.forEach { contentResolver.delete(it, null, null) }
                true
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != TRASH_REQUEST) return
        trashing?.success(resultCode == RESULT_OK)
        trashing = null
    }

    private companion object {
        const val ACCESS_REQUEST = 7001
        const val TRASH_REQUEST = 7002
    }
}
