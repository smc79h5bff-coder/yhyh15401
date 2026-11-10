package com.example.docdiff

import android.app.ActivityManager
import android.content.ClipData
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.Charset

class MainActivity : FlutterActivity() {

    companion object {
        private const val SHARE_CHANNEL = "docdiff/share_intent"
        private const val ACTION_DUPEBOX_SCAN = "com.dupebox.dupe_box.ACTION_SCAN_FOLDER"

        /// 还没被 Flutter 取走的分享文件列表。
        /// 每个条目是 mapOf("path" to 绝对路径, "name" to 显示名)。
        @Volatile
        private var pendingShares: List<Map<String, String>> = emptyList()

        private fun Context.shareCacheDir(): File {
            val dir = File(cacheDir, "share_intent")
            if (!dir.exists()) dir.mkdirs()
            return dir
        }

        /** 清理超过 3 天的旧分享缓存。 */
        fun cleanupShareCache(ctx: Context) {
            val root = ctx.shareCacheDir()
            val cutoff = System.currentTimeMillis() - 3L * 24 * 3600 * 1000
            root.listFiles()?.forEach { f ->
                if (f.isFile && f.lastModified() < cutoff) f.delete()
            }
        }
    }

    private var shareChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // —— 退出信息查询 ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "docdiff/exit_info")
            .setMethodCallHandler { call, result ->
                if (call.method == "getLastExitInfo") {
                    result.success(getLastExitInfo())
                } else {
                    result.notImplemented()
                }
            }

        // —— 分享进来的文件 ——
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingShares" -> {
                    val out = pendingShares
                    pendingShares = emptyList()
                    result.success(out)
                }
                else -> result.notImplemented()
            }
        }

        // —— 编码解码（GBK/GB2312/GB18030/Big5/Shift-JIS 走系统 ICU） ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "docdiff/encoding")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "decode" -> {
                        try {
                            val bytes = call.argument<ByteArray>("bytes")
                            val charsetName = call.argument<String>("charset") ?: "UTF-8"
                            if (bytes == null) {
                                result.error("ARG", "bytes is null", null)
                                return@setMethodCallHandler
                            }
                            val charset = when (charsetName) {
                                "GB2312" -> Charset.forName("GBK")   // GB2312 ⊂ GBK
                                "Shift-JIS" -> Charset.forName("Shift_JIS")
                                else -> Charset.forName(charsetName)
                            }
                            // String(bytes, Charset) 对非法字节输出 U+FFFD，不抛异常
                            result.success(String(bytes, charset))
                        } catch (e: Exception) {
                            result.error("DECODE", e.message ?: "decode failed", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // —— 文件操作广播（删/移后通知 DupeBox 刷新结果）——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "docdiff/file_op")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendFileOp" -> {
                        val path = call.argument<String>("path") ?: ""
                        val op = call.argument<String>("op") ?: "delete"
                        try {
                            val i = Intent("com.dupebox.dupe_box.ACTION_FILE_OP").apply {
                                setPackage("com.dupebox.dupe_box")
                                putExtra("path", path)
                                putExtra("op", op)
                            }
                            sendBroadcast(i)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("BCAST", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // —— 跳转到 DupeBox 扫描指定文件夹（docdiff 文件浏览器"查找重复"）——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "docdiff/dupebox_launcher")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanFolder" -> {
                        val folderPaths =
                            call.argument<ArrayList<String>>("folderPaths")
                                ?: arrayListOf()
                        try {
                            val dupeBoxPkg = "com.dupebox.dupe_box"
                            val i = Intent(ACTION_DUPEBOX_SCAN).apply {
                                component =
                                    ComponentName(dupeBoxPkg, "$dupeBoxPkg.MainActivity")
                                putStringArrayListExtra("folderPaths", folderPaths)
                                putExtra("fromDocdiff", true)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            if (i.resolveActivity(packageManager) != null) {
                                startActivity(i)
                                result.success(true)
                            } else {
                                result.error("NO_DUPEBOX", "未安装 DupeBox，请先安装", null)
                            }
                        } catch (e: Exception) {
                            result.error("LAUNCH", e.message, null)
                        }
                    }
                    // 从 docdiff 对比页返回时，把已运行的 DupeBox 重新带到前台。
                    "returnToDupeBox" -> {
                        try {
                            val dupeBoxPkg = "com.dupebox.dupe_box"
                            val i = Intent().apply {
                                component =
                                    ComponentName(dupeBoxPkg, "$dupeBoxPkg.MainActivity")
                                // NEW_TASK 进入 DupeBox 自己的任务栈；
                                // REORDER_TO_FRONT 若已存在则直接提到前台，而非新建。
                                addFlags(
                                    Intent.FLAG_ACTIVITY_NEW_TASK
                                        or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                                )
                            }
                            if (i.resolveActivity(packageManager) != null) {
                                startActivity(i)
                                result.success(true)
                            } else {
                                result.error("NO_DUPEBOX", "未安装 DupeBox，请先安装", null)
                            }
                        } catch (e: Exception) {
                            result.error("LAUNCH", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent)
    }

    /** 热启动（App 已经在栈顶）会走这里；singleTop 模式下不会新建 Activity。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        when (action) {
            Intent.ACTION_SEND -> {
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    ?: return
                val cached = copyUriToCache(uri, null, false) ?: return
                pendingShares = listOf(cached)
                // 通知 Flutter 侧去取
                dispatchShareEvent()
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris: List<Uri> = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    ?: intent.clipData?.let { cd ->
                        (0 until cd.itemCount).mapNotNull { cd.getItemAt(it).uri }
                    }
                    ?: return
                // 来自 DupeBox 时携带真实路径与来源标记，供对比页启用删除/回收站。
                val origPathA = intent.getStringExtra("origPathA")
                val origPathB = intent.getStringExtra("origPathB")
                val fromDupeBox = intent.getBooleanExtra("fromDupeBox", false)
                val copied = mutableListOf<Map<String, String>>()
                uris.forEachIndexed { index, u ->
                    val orig = if (index == 0) origPathA else origPathB
                    val m = copyUriToCache(u, orig, fromDupeBox)
                    if (m != null) copied.add(m)
                }
                if (copied.isNotEmpty()) {
                    pendingShares = copied
                    dispatchShareEvent()
                }
            }
        }
    }

    private fun dispatchShareEvent() {
        val channel = shareChannel ?: return
        runOnUiThread {
            channel.invokeMethod("onSharesPending", null)
        }
    }

    /** 把分享的 URI 转成一个本地可读取的临时文件。
     *  content://  → 先复制到 cache/share_intent 再返回
     *  file:// 且在 cache 内 → 直接用（防插件覆盖）
     *  file:// 且是用户真实文件 → 直接返回原路径，绝不复制
     *
     *  [origPath] 由 DupeBox 通过 intent extra 传入的真实路径（SAF/SD 卡文件可能为空，
     *  此时尝试用 [contentUriToRealPath] 解析）；[fromDupeBox] 标记来源。
     *  返回的 map 额外携带 origPath / uri / fromDupeBox，供对比页启用删除与回收站。
     */
    private fun copyUriToCache(
        uri: Uri,
        origPath: String?,
        fromDupeBox: Boolean,
    ): Map<String, String>? {
        return try {
            val resolver = contentResolver
            var resolvedOrig = origPath?.takeIf { it.isNotEmpty() }
            if (resolvedOrig == null && uri.scheme == "file") resolvedOrig = uri.path
            if (resolvedOrig == null && uri.scheme == "content") {
                resolvedOrig = contentUriToRealPath(uri)
            }

            // 尝试 file://
            if (uri.scheme == "file" && uri.path != null) {
                val path = uri.path!!
                val name = path.substringAfterLast('/')
                val cacheRoot = cacheDir.absolutePath
                if (path.startsWith(cacheRoot)) {
                    // 已经在缓存里了，检查是不是我们自己的目录
                    if (path.contains("/share_compare/")) {
                        // 这是上一轮对比页刚生成的，不能再复制，否则路径重合
                        return shareItem(path, name, resolvedOrig, uri, fromDupeBox)
                    }
                }
                // 其他 file:// 一律复制，避免原文件被删或被同名覆盖
                val dest = copyStreamTo(uri, resolver, name) ?: return null
                return shareItem(dest.absolutePath, name, resolvedOrig, uri, fromDupeBox)
            }

            // content:// — 查显示名 + 复制
            var displayName = "shared_${System.currentTimeMillis()}"
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val dn = c.getString(0)
                    if (!dn.isNullOrEmpty()) displayName = dn
                }
            }
            val dest = copyStreamTo(uri, resolver, displayName) ?: return null
            shareItem(dest.absolutePath, displayName, resolvedOrig, uri, fromDupeBox)
        } catch (e: Exception) {
            null
        }
    }

    /** 构造分享条目：临时副本路径 + 显示名 + 原始真实路径 + 源 URI + 来源标记。 */
    private fun shareItem(
        path: String,
        name: String,
        origPath: String?,
        uri: Uri,
        fromDupeBox: Boolean,
    ): Map<String, String> = mapOf(
        "path" to path,
        "name" to name,
        "origPath" to (origPath ?: ""),
        "uri" to uri.toString(),
        "fromDupeBox" to fromDupeBox.toString(),
    )

    /** 把 SAF/媒体库的 content:// 文档 URI 解析成真实文件系统路径。
     *  需要 MANAGE_EXTERNAL_STORAGE（本 App 启动即要求）。解析失败返回 null。
     *  例如 primary:Download/a.txt → /storage/emulated/0/Download/a.txt；
     *  <uuid>:DCIM/a.jpg      → /storage/<uuid>/DCIM/a.jpg。
     */
    private fun contentUriToRealPath(uri: Uri): String? {
        return try {
            if (uri.scheme == "file") return uri.path
            val docId = DocumentsContract.getDocumentId(uri) ?: return null
            val colon = docId.indexOf(':')
            if (colon < 0) return null
            val volume = docId.substring(0, colon)
            val relative = docId.substring(colon + 1)
            val root = when (volume) {
                "primary" -> Environment.getExternalStorageDirectory().absolutePath
                else -> "/storage/$volume"
            }
            "$root/$relative"
        } catch (e: Exception) {
            null
        }
    }

    private fun copyStreamTo(uri: Uri, resolver: android.content.ContentResolver, name: String): File? {
        val safeName = System.currentTimeMillis().toString(16) + "_" + name
        val dest = File(shareCacheDir(), safeName)
        resolver.openInputStream(uri)?.use { input ->
            FileOutputStream(dest).use { out ->
                input.copyTo(out)
            }
        } ?: return null
        return dest
    }

    /// 查询上一次进程的退出记录（Android 11+ 的 ApplicationExitInfo）。
    private fun getLastExitInfo(): Map<String, Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val am = getSystemService(ActivityManager::class.java) ?: return null
        val infos = try {
            am.getHistoricalProcessExitReasons(packageName, 0, 1)
        } catch (e: Exception) {
            null
        }
        if (infos == null || infos.isEmpty()) return null
        val info = infos[0]
        return mapOf(
            "reason" to info.reason,
            "description" to (info.description ?: ""),
            "timestamp" to info.timestamp
        )
    }
}
