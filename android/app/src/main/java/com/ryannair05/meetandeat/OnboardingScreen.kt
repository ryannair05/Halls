package com.ryannair05.meetandeat

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.milliseconds

@Composable
fun OnboardingScreen(onGetStarted: () -> Unit) {
    TrackScreen("onboarding")
    val reveal = remember { Animatable(0f) }
    val outline = remember { Animatable(0f) }
    val finish = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        launch { outline.animateTo(1f, tween(750)); finish.animateTo(1f, tween(500)) }
        delay(700.milliseconds)
        reveal.animateTo(1f, tween(550))
    }
    val blue = Color(0xFF086DDA)
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).background(
        Brush.verticalGradient(listOf(blue.copy(alpha = 0.12f), Color.Transparent))
    )) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing), horizontalAlignment = Alignment.CenterHorizontally) {
            Column(Modifier.weight(1f).widthIn(max = 520.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Canvas(Modifier.size(150.dp)) {
                    scale(size.width / 1024f, size.height / 1024f, pivot = androidx.compose.ui.geometry.Offset.Zero) {
                        drawPath(bubbleLogoPath, Brush.linearGradient(listOf(Color.Cyan, blue), end = androidx.compose.ui.geometry.Offset(1024f, 1024f)), alpha = 0.08f + finish.value * 0.92f)
                        val measure = PathMeasure().apply { setPath(bubbleLogoPath, false) }
                        val segment = Path()
                        measure.getSegment(0f, measure.length * outline.value, segment)
                        drawPath(segment, Color.Cyan, style = Stroke(width = 10f), alpha = 1f - finish.value * 0.8f)
                        drawPath(forkLogoPath, Color.White, alpha = finish.value)
                    }
                }
                Text("Halls", fontSize = 38.sp, fontWeight = FontWeight.Bold, letterSpacing = (-1).sp)
                Text("Your campus day, simplified.", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Column(Modifier.graphicsLayer { alpha = reveal.value; translationY = (1f - reveal.value) * 24f }, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("AT PENN STATE", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, letterSpacing = 2.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OnboardingCard("Meals", listOf("Five dining halls", "Search across halls", "Buffet & venue hours"), Icons.Default.Restaurant, blue, Modifier.weight(1f))
                        OnboardingCard("CATA", listOf("Live bus tracking", "Route maps", "Choose your routes"), Icons.Default.DirectionsBus, Color(0xFF6264D9), Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OnboardingCard("My Meals", listOf("Plan & log meals", "Nutrition & portions", "History & CSV export"), Icons.Default.Eco, Color(0xFF188679), Modifier.weight(1f))
                        OnboardingCard("Campus Rec", listOf("Facility schedules", "Campus activities", "Interactive IM map"), Icons.AutoMirrored.Filled.DirectionsRun, Color(0xFFB96B17), Modifier.weight(1f))
                    }
                    Text("Nutrition facts, allergen details, and dietary filters help you choose your next meal.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Surface(color = MaterialTheme.colorScheme.surfaceContainer.copy(alpha = 0.96f)) {
                Column(Modifier.widthIn(max = 520.dp).fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("For Penn State", style = MaterialTheme.typography.labelLarge)
                    Button(onClick = onGetStarted, modifier = Modifier.fillMaxWidth().height(58.dp), shape = MaterialTheme.shapes.large, colors = ButtonDefaults.buttonColors(containerColor = blue, contentColor = Color.White)) {
                        Spacer(Modifier.weight(1f)); Text("Get Started", fontWeight = FontWeight.Bold); Spacer(Modifier.weight(1f)); Icon(Icons.AutoMirrored.Filled.ArrowForward, null)
                    }
                }
            }
        }
    }
}

@Composable
private fun OnboardingCard(title: String, bullets: List<String>, symbol: ImageVector, color: Color, modifier: Modifier) {
    Surface(modifier.heightIn(min = 176.dp), shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.surfaceContainerLowest) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Surface(color = color.copy(alpha = 0.12f), shape = MaterialTheme.shapes.medium) { Icon(symbol, null, Modifier.padding(8.dp).size(22.dp), tint = color) }
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            bullets.forEach { Text("• $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}
