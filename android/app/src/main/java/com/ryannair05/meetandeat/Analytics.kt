package com.ryannair05.meetandeat

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import com.google.firebase.FirebaseApp
import androidx.compose.ui.platform.LocalContext
import com.google.firebase.Firebase
import com.google.firebase.analytics.FirebaseAnalytics
import com.google.firebase.analytics.analytics
import com.google.firebase.analytics.logEvent

/** Track Compose destinations explicitly; activity tracking cannot distinguish them. */
@Composable
internal fun TrackScreen(name: String, destination: String = name) {
    val context = LocalContext.current.applicationContext
    LaunchedEffect(name, destination) {
        if (FirebaseApp.getApps(context).isEmpty()) return@LaunchedEffect
        Firebase.analytics.logEvent(FirebaseAnalytics.Event.SCREEN_VIEW) {
            param(FirebaseAnalytics.Param.SCREEN_NAME, name)
            param(FirebaseAnalytics.Param.SCREEN_CLASS, destination)
        }
    }
}
