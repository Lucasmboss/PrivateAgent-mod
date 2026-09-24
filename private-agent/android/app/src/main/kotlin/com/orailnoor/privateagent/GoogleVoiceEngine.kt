package com.orailnoor.privateagent

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import java.util.Locale

/**
 * Android-native voice adapter.
 *
 * It deliberately selects Google's installed speech services instead of
 * silently claiming that any arbitrary recognition/TTS provider is Google.
 * The Flutter layer can fall back to its existing plugins when these services
 * are not installed on a device.
 */
class GoogleVoiceEngine(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit
) : RecognitionListener {
    companion object {
        private const val GOOGLE_SEARCH_PACKAGE = "com.google.android.googlequicksearchbox"
        private const val GOOGLE_TTS_PACKAGE = "com.google.android.tts"
    }

    private var recognizer: SpeechRecognizer? = null
    private var recognitionComponent: ComponentName? = null
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var listening = false

    fun initialize(): Map<String, Any?> {
        if (recognizer == null) {
            recognitionComponent = findGoogleRecognitionComponent()
            recognizer = recognitionComponent?.let {
                SpeechRecognizer.createSpeechRecognizer(context, it)
            }
            recognizer?.setRecognitionListener(this)
        }

        if (textToSpeech == null && isPackageInstalled(GOOGLE_TTS_PACKAGE)) {
            textToSpeech = TextToSpeech(
                context,
                TextToSpeech.OnInitListener { status ->
                    ttsReady = status == TextToSpeech.SUCCESS
                    if (ttsReady) {
                        configureTtsLanguage()
                    }
                    emit(
                        mapOf(
                            "type" to "ttsReady",
                            "available" to ttsReady,
                            "engine" to GOOGLE_TTS_PACKAGE
                        )
                    )
                },
                GOOGLE_TTS_PACKAGE
            )
        }

        return mapOf(
            "speechAvailable" to (recognizer != null),
            "ttsInstalled" to isPackageInstalled(GOOGLE_TTS_PACKAGE),
            "ttsReady" to ttsReady,
            "speechEngine" to (recognitionComponent?.packageName ?: ""),
            "ttsEngine" to if (isPackageInstalled(GOOGLE_TTS_PACKAGE)) {
                GOOGLE_TTS_PACKAGE
            } else {
                ""
            }
        )
    }

    fun isGoogleVoiceAvailable(): Boolean {
        return findGoogleRecognitionComponent() != null ||
            isPackageInstalled(GOOGLE_TTS_PACKAGE)
    }

    fun startListening(languageTag: String?): Boolean {
        if (recognizer == null) initialize()
        val speechRecognizer = recognizer ?: run {
            emit(
                mapOf(
                    "type" to "error",
                    "code" to "speech_unavailable",
                    "message" to "Google Speech Services is not installed."
                )
            )
            return false
        }

        val language = languageTag?.takeIf { it.isNotBlank() } ?: "es-AR"
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, language)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        }

        listening = true
        speechRecognizer.startListening(intent)
        emit(mapOf("type" to "listening", "language" to language))
        return true
    }

    fun stopListening() {
        listening = false
        recognizer?.stopListening()
        emit(mapOf("type" to "stopped"))
    }

    fun speak(text: String, languageTag: String?): Boolean {
        if (text.isBlank()) return false
        if (textToSpeech == null) initialize()
        val tts = textToSpeech
        if (tts == null || !ttsReady) {
            emit(
                mapOf(
                    "type" to "error",
                    "code" to "tts_unavailable",
                    "message" to "Google Text-to-Speech is not installed or ready."
                )
            )
            return false
        }

        configureTtsLanguage(languageTag)
        val utteranceId = "privateagent-${System.nanoTime()}"
        val result = tts.speak(
            text,
            TextToSpeech.QUEUE_FLUSH,
            Bundle(),
            utteranceId
        )
        if (result == TextToSpeech.ERROR) {
            emit(
                mapOf(
                    "type" to "error",
                    "code" to "tts_failed",
                    "message" to "Google Text-to-Speech could not start."
                )
            )
            return false
        }
        emit(mapOf("type" to "speaking", "utteranceId" to utteranceId))
        return true
    }

    fun stopSpeaking() {
        textToSpeech?.stop()
        emit(mapOf("type" to "speechStopped"))
    }

    fun dispose() {
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        ttsReady = false
        listening = false
    }

    override fun onReadyForSpeech(params: Bundle?) {
        emit(mapOf("type" to "ready"))
    }

    override fun onBeginningOfSpeech() {
        emit(mapOf("type" to "begin"))
    }

    override fun onRmsChanged(rmsdB: Float) = Unit

    override fun onBufferReceived(buffer: ByteArray?) = Unit

    override fun onEndOfSpeech() {
        listening = false
        emit(mapOf("type" to "end"))
    }

    override fun onError(error: Int) {
        listening = false
        emit(
            mapOf(
                "type" to "error",
                "code" to "recognition_$error",
                "message" to recognitionErrorMessage(error)
            )
        )
    }

    override fun onResults(results: Bundle?) {
        listening = false
        val text = results
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            .orEmpty()
        if (text.isNotBlank()) {
            emit(mapOf("type" to "final", "text" to text))
        }
    }

    override fun onPartialResults(partialResults: Bundle?) {
        val text = partialResults
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            .orEmpty()
        if (text.isNotBlank()) {
            emit(mapOf("type" to "partial", "text" to text))
        }
    }

    override fun onEvent(eventType: Int, params: Bundle?) = Unit

    private fun findGoogleRecognitionComponent(): ComponentName? {
        val services = context.packageManager.queryIntentServices(
            Intent(RecognitionService.SERVICE_INTERFACE),
            PackageManager.MATCH_ALL
        )
        val googleService = services.firstOrNull {
            it.serviceInfo.packageName == GOOGLE_SEARCH_PACKAGE
        } ?: return null
        return ComponentName(
            googleService.serviceInfo.packageName,
            googleService.serviceInfo.name
        )
    }

    private fun configureTtsLanguage(languageTag: String? = null) {
        val locale = Locale.forLanguageTag(
            languageTag?.takeIf { it.isNotBlank() } ?: "es-AR"
        )
        val result = textToSpeech?.setLanguage(locale)
        if (result == TextToSpeech.LANG_MISSING_DATA ||
            result == TextToSpeech.LANG_NOT_SUPPORTED
        ) {
            textToSpeech?.language = Locale.forLanguageTag("es-ES")
        }
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            context.packageManager.getPackageInfo(packageName, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun recognitionErrorMessage(error: Int): String {
        return when (error) {
            SpeechRecognizer.ERROR_AUDIO -> "Audio recording failed."
            SpeechRecognizer.ERROR_CLIENT -> "Speech recognition client error."
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is required."
            SpeechRecognizer.ERROR_NETWORK,
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Google Speech Services network error."
            SpeechRecognizer.ERROR_NO_MATCH -> "No speech was recognized."
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognition is busy."
            SpeechRecognizer.ERROR_SERVER -> "Google Speech Services server error."
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was detected."
            else -> "Speech recognition failed."
        }
    }
}