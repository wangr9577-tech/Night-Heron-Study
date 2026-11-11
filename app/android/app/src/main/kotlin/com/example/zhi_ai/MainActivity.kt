package com.example.zhi_ai

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val pdfWorker = Executors.newSingleThreadExecutor()
    private val uiHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zhi/local_pdf").setMethodCallHandler { call, result ->
            if (call.method != "pageCount" && call.method != "renderPage") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val rawPath = call.argument<String>("path")
            val pageIndex = call.argument<Int>("page") ?: 0
            pdfWorker.execute {
                try {
                    requireNotNull(rawPath)
                    val root = File(applicationInfo.dataDir, "app_flutter/local_sources").canonicalFile
                    val file = File(rawPath).canonicalFile
                    require(file.path.startsWith(root.path + File.separator) && file.isFile)
                    val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                    val renderer = try { PdfRenderer(descriptor) } catch (e: Exception) { descriptor.close(); throw e }
                    try {
                        if (call.method == "pageCount") {
                            val count = renderer.pageCount
                            uiHandler.post { result.success(count) }
                        } else {
                            require(pageIndex in 0 until renderer.pageCount)
                            renderer.openPage(pageIndex).use { page ->
                                val width = 1080
                                val height = (page.height.toDouble() * width / page.width).toInt().coerceIn(1, 4096)
                                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                                try {
                                    bitmap.eraseColor(Color.WHITE)
                                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    val bytes = ByteArrayOutputStream().use { output ->
                                        check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                                        output.toByteArray()
                                    }
                                    uiHandler.post { result.success(bytes) }
                                } finally { bitmap.recycle() }
                            }
                        }
                    } finally { renderer.close() }
                } catch (e: Exception) {
                    uiHandler.post { result.error("pdf_error", "无法打开 PDF 页面", null) }
                }
            }
        }
    }

    override fun onDestroy() {
        pdfWorker.shutdown()
        super.onDestroy()
    }
}
