package com.github.wgh136.venera

import android.Manifest
import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import androidx.activity.result.ActivityResultCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import dev.flutter.packages.file_selector_android.FileUtils
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterFragmentActivity() {
    var volumeListen = VolumeListen()
    var listening = false

    private val storageRequestCode = 0x10
    private var storagePermissionRequest: ((Boolean) -> Unit)? = null

    private val nextLocalRequestCode = AtomicInteger()

    private val sharedTexts = ArrayList<String>()

    private var textShareHandler: ((String) -> Unit)? = null

    /// The app was opened from a notification of [DownloadService] to resume
    /// the downloads.
    private var resumeDownloads = false

    private val notificationRequestCode = 0x11

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        resumeDownloads = intent?.getBooleanExtra(DownloadService.EXTRA_RESUME, false) == true

        if (intent?.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(DownloadService.EXTRA_RESUME, false)) {
            val action = DownloadService.onAction
            if (action != null) action("resume") else resumeDownloads = true
        }
        if (intent.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    private fun handleSharedText(text: String) {
        if (textShareHandler != null) {
            textShareHandler?.invoke(text)
        } else {
            sharedTexts.add(text)
        }
    }

    private fun <I, O> startContractForResult(
        contract: ActivityResultContract<I, O>,
        input: I,
        callback: ActivityResultCallback<O>
    ) {
        val key = "activity_rq_for_result#${nextLocalRequestCode.getAndIncrement()}"
        val registry = activityResultRegistry
        var launcher: ActivityResultLauncher<I>? = null
        val observer = object : LifecycleEventObserver {
            override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
                if (Lifecycle.Event.ON_DESTROY == event) {
                    launcher?.unregister()
                    lifecycle.removeObserver(this)
                }
            }
        }
        lifecycle.addObserver(observer)
        val newCallback = ActivityResultCallback<O> {
            launcher?.unregister()
            lifecycle.removeObserver(observer)
            callback.onActivityResult(it)
        }
        launcher = registry.register(key, contract, newCallback)
        launcher.launch(input)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "venera/method_channel"
        ).setMethodCallHandler { call, res ->
            when (call.method) {
                "getProxy" -> res.success(getProxy())
                "isActiveNetworkMetered" -> {
                    val connectivity = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                    res.success(connectivity.isActiveNetworkMetered)
                }
                "setScreenOn" -> {
                    val set = call.argument<Boolean>("set") ?: false
                    if (set) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    res.success(null)
                }

                "getDirectoryPath" -> {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent) { activityResult ->
                        if (activityResult.resultCode != Activity.RESULT_OK) {
                            res.success(null)
                            return@startContractForResult
                        }
                        val pickedDirectoryUri = activityResult.data?.data
                        if (pickedDirectoryUri == null)
                            res.success(null)
                        else
                            onPickedDirectory(pickedDirectoryUri, res)
                    }
                }

                else -> res.notImplemented()
            }
        }

        val channel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/volume")
        channel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    listening = true
                    volumeListen.onUp = {
                        events.success(1)
                    }
                    volumeListen.onDown = {
                        events.success(2)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    listening = false
                }
            })

        val storageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/storage")
        storageChannel.setMethodCallHandler { _, res ->
            requestStoragePermission { result ->
                res.success(result)
            }
        }

        val selectFileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/select_file")
        selectFileChannel.setMethodCallHandler { req, res ->
            when (req.method) {
                "selectFiles" -> openFiles(res, req.arguments<String>()!!)
                "selectFolder" -> openFolder(res)
                "videoThumbnail" -> videoThumbnail(res, req.arguments<String>()!!)
                "copyUri" -> copyUri(
                    res,
                    req.argument<String>("uri")!!,
                    req.argument<String>("path")!!
                )
                else -> {
                    val mimeType = req.arguments<String>()
                    openFile(res, mimeType!!)
                }
            }
        }

        val downloadChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/download_service")
        DownloadService.onAction = { action -> downloadChannel.invokeMethod(action, null) }
        downloadChannel.setMethodCallHandler { call, res ->
            when (call.method) {
                "update" -> {
                    DownloadService.update(
                        applicationContext,
                        DownloadService.Status(
                            state = call.argument<String>("state")!!,
                            title = call.argument<String>("title")!!,
                            text = call.argument<String>("text")!!,
                            subText = call.argument<String>("subText"),
                            progress = call.argument<Double>("progress")!!,
                            pauseLabel = call.argument<String>("pause")!!,
                            resumeLabel = call.argument<String>("resume")!!,
                        )
                    )
                    res.success(null)
                }

                "finish" -> {
                    DownloadService.finish(
                        applicationContext,
                        call.argument<String>("title"),
                        call.argument<String>("text")
                    )
                    res.success(null)
                }

                "requestPermission" -> {
                    requestNotificationPermission()
                    res.success(null)
                }

                "takeResumeRequest" -> {
                    res.success(resumeDownloads)
                    resumeDownloads = false
                }

                // Finishing the activity destroys the Flutter engine, and
                // the downloads with it.
                "moveTaskToBack" -> {
                    moveTaskToBack(true)
                    res.success(null)
                }

                else -> res.notImplemented()
            }
        }

        val shareTextChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/text_share")
        shareTextChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    textShareHandler = {text ->
                        events.success(text)
                    }
                    if (sharedTexts.isNotEmpty()) {
                        for (text in sharedTexts) {
                            events.success(text)
                        }
                        sharedTexts.clear()
                    }
                }

                override fun onCancel(arguments: Any?) {
                    textShareHandler = null
                }
            })
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        super.cleanUpFlutterEngine(flutterEngine)
        DownloadService.engineGone(applicationContext)
    }

    override fun onResume() {
        super.onResume()
        DownloadService.onAppVisible(applicationContext)
    }

    /// Asks for the permission to post notifications (Android 13+), which
    /// show the progress of the downloads. Android asks the user at most
    /// twice.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) return
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationRequestCode
        )
    }

    private fun getProxy(): String {
        val host = System.getProperty("http.proxyHost")
        val port = System.getProperty("http.proxyPort")
        return if (host != null && port != null) {
            "$host:$port"
        } else {
            "No Proxy"
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (listening) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeListen.down()
                    return true
                }

                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeListen.up()
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /// Ensure that the directory is accessible by dart:io
    private fun onPickedDirectory(uri: Uri, result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            var plain = uri.toString()
            if(plain.contains("%3A")) {
                plain = Uri.decode(plain)
            }
            val externalStoragePrefix = "content://com.android.externalstorage.documents/tree/primary:";
            if(plain.startsWith(externalStoragePrefix)) {
                val path = plain.substring(externalStoragePrefix.length)
                result.success(Environment.getExternalStorageDirectory().absolutePath + "/" + path)
            }
            // The uri cannot be parsed to plain path, use copy method
        }
        // dart:io cannot access the directory without permission.
        // so we need to copy the directory to cache directory
        val contentResolver = contentResolver
        var tmp = cacheDir
        var dirName = DocumentFile.fromTreeUri(this, uri)?.name
        tmp = File(tmp, dirName!!)
        if(tmp.exists()) {
            tmp.deleteRecursively()
        }
        tmp.mkdir()
        Thread {
            try {
                copyDirectory(contentResolver, uri, tmp)
                result.success(tmp.absolutePath)
            }
            catch (e: Exception) {
                result.error("copy error", e.message, null)
            }
        }.start()

    }

    private fun copyDirectory(resolver: ContentResolver, srcUri: Uri, destDir: File) {
        val src = DocumentFile.fromTreeUri(this, srcUri) ?: return
        for (file in src.listFiles()) {
            if (file.isDirectory) {
                val newDir = File(destDir, file.name!!)
                newDir.mkdir()
                copyDirectory(resolver, file.uri, newDir)
            } else {
                val newFile = File(destDir, file.name!!)
                resolver.openInputStream(file.uri)?.use { input ->
                    FileOutputStream(newFile).use { output ->
                        input.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                        output.flush()
                    }
                }
            }
        }
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED && ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            Environment.isExternalStorageManager()
        }
    }

    private fun requestStoragePermission(result: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            val readPermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            val writePermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            if (!readPermission || !writePermission) {
                storagePermissionRequest = result
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE
                    ),
                    storageRequestCode
                )
            } else {
                result(true)
            }
        } else {
            if (!Environment.isExternalStorageManager()) {
                try {
                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    intent.addCategory("android.intent.category.DEFAULT")
                    intent.data = Uri.parse("package:$packageName")
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ _ ->
                        result(Environment.isExternalStorageManager())
                    }
                } catch (e: Exception) {
                    result(false)
                }
            } else {
                result(true)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == storageRequestCode) {
            storagePermissionRequest?.invoke(grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            })
            storagePermissionRequest = null
        }
    }

    private fun openFile(result: MethodChannel.Result, mimeType: String) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = mimeType
        startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ activityResult ->
            if (activityResult.resultCode != Activity.RESULT_OK) {
                result.success(null)
                return@startContractForResult
            }
            val uri = activityResult.data?.data
            if (uri == null) {
                result.success(null)
                return@startContractForResult
            }
            val contentResolver = contentResolver
            val file = DocumentFile.fromSingleUri(this, uri)
            if (file == null) {
                result.success(null)
                return@startContractForResult
            }
            val fileName = file.name
            if (fileName == null) {
                result.success(null)
                return@startContractForResult
            }
            if(hasStoragePermission()) {
                try {
                    val filePath = FileUtils.getPathFromUri(this, uri)
                    result.success(filePath)
                    return@startContractForResult
                }
                catch (e: Exception) {
                    // ignore
                }
            }
            // use copy method
            val tmp = File(cacheDir, fileName)
            if(tmp.exists()) {
                tmp.delete()
            }
            Log.i("Venera", "copy file (${fileName}) to ${tmp.absolutePath}")
            Thread {
                try {
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(tmp).use { output ->
                            input.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                            output.flush()
                        }
                    }
                    result.success(tmp.absolutePath)
                }
                catch (e: Exception) {
                    result.error("copy error", e.message, null)
                }
            }.start()
        }
    }

    /// Picks several files and returns their uris and names, without
    /// copying them: large files (videos) are copied once, by [copyUri].
    private fun openFiles(result: MethodChannel.Result, mimeType: String) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = mimeType
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        startContractForResult(ActivityResultContracts.StartActivityForResult(), intent) { activityResult ->
            if (activityResult.resultCode != Activity.RESULT_OK) {
                result.success(null)
                return@startContractForResult
            }
            val data = activityResult.data
            val uris = mutableListOf<Uri>()
            val clip = data?.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) {
                    uris.add(clip.getItemAt(i).uri)
                }
            } else {
                data?.data?.let { uris.add(it) }
            }
            val files = uris.mapNotNull { uri ->
                val name = DocumentFile.fromSingleUri(this, uri)?.name ?: return@mapNotNull null
                mapOf("uri" to uri.toString(), "name" to name)
            }
            result.success(files)
        }
    }

    /// Copies the content of [uri] into the file [path].
    private fun copyUri(result: MethodChannel.Result, uri: String, path: String) {
        Thread {
            try {
                val input = contentResolver.openInputStream(Uri.parse(uri))
                    ?: throw Exception("Cannot open $uri")
                input.use {
                    FileOutputStream(File(path)).use { output ->
                        input.copyTo(output, bufferSize = 1024 * 1024)
                        output.flush()
                    }
                }
                runOnUiThread { result.success(null) }
            } catch (e: Exception) {
                runOnUiThread { result.error("copy error", e.message, null) }
            }
        }.start()
    }
    /// Picks a folder and lists its files, and the files of its subfolders,
    /// as uris without copying them: `{"name", "files": [{"name", "uri",
    /// "nested"}]}`.
    private fun openFolder(result: MethodChannel.Result) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startContractForResult(ActivityResultContracts.StartActivityForResult(), intent) { activityResult ->
            val uri = activityResult.data?.data
            if (activityResult.resultCode != Activity.RESULT_OK || uri == null) {
                result.success(null)
                return@startContractForResult
            }
            Thread {
                try {
                    val root = DocumentFile.fromTreeUri(this, uri)
                        ?: throw Exception("Cannot open $uri")
                    val files = mutableListOf<Map<String, Any>>()
                    for (file in root.listFiles()) {
                        if (file.isDirectory) {
                            for (child in file.listFiles()) {
                                val name = child.name ?: continue
                                if (child.isFile) {
                                    files.add(mapOf("name" to name, "uri" to child.uri.toString(), "nested" to true))
                                }
                            }
                        } else {
                            val name = file.name ?: continue
                            files.add(mapOf("name" to name, "uri" to file.uri.toString(), "nested" to false))
                        }
                    }
                    val folder = mapOf("name" to (root.name ?: ""), "files" to files)
                    runOnUiThread { result.success(folder) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("list error", e.message, null) }
                }
            }.start()
        }
    }

    /// A JPEG frame from a tenth into the video file [path], at most a
    /// minute in, or null.
    private fun videoThumbnail(result: MethodChannel.Result, path: String) {
        Thread {
            val retriever = MediaMetadataRetriever()
            var data: ByteArray? = null
            try {
                retriever.setDataSource(path)
                val duration = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION
                )?.toLongOrNull() ?: 0L
                val at = minOf(duration / 10, 60_000L) * 1000
                val frame = retriever.getFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: retriever.frameAtTime
                if (frame != null) {
                    val out = ByteArrayOutputStream()
                    frame.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    frame.recycle()
                    data = out.toByteArray()
                }
            } catch (e: Exception) {
                Log.w("Venera", "No thumbnail for $path: ${e.message}")
            } finally {
                try { retriever.release() } catch (_: Exception) {}
            }
            runOnUiThread { result.success(data) }
        }.start()
    }
}

class VolumeListen {
    var onUp = fun() {}
    var onDown = fun() {}
    fun up() {
        onUp()
    }

    fun down() {
        onDown()
    }
}

