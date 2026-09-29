package com.ryannair05.meetandeat.share

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

object ShareImageExporter {
    suspend fun export(
        context: Context,
        graphicsLayer: GraphicsLayer,
        fileNamePrefix: String = "menu-share",
    ): Uri {
        val bitmap = graphicsLayer.toImageBitmap().asAndroidBitmap()
        return withContext(Dispatchers.IO) {
            val output = File(context.cacheDir, "shared-menus").apply { mkdirs() }
            output.listFiles()?.forEach { stale ->
                if (System.currentTimeMillis() - stale.lastModified() > CACHE_MAX_AGE_MILLIS) stale.delete()
            }
            val imageFile = File(output, "$fileNamePrefix-${System.currentTimeMillis()}.png")
            FileOutputStream(imageFile).use { stream ->
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                    "The menu image could not be encoded."
                }
            }
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", imageFile)
        }
    }

    fun share(
        context: Context,
        image: Uri,
        chooserTitle: String = "Share menu card",
        clipLabel: String = "Menu card",
    ) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, image)
            clipData = android.content.ClipData.newUri(context.contentResolver, clipLabel, image)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, chooserTitle))
    }

    private const val CACHE_MAX_AGE_MILLIS = 24 * 60 * 60 * 1000L
}
