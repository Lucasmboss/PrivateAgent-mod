package com.orailnoor.privateagent

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
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
    private var holdToTalk = false
    private var stoppingHoldToTalk = false
    private var activeLanguage = "es-AR"
    private var currentPartial = ""
    private var speechText = ""
    private var speechResumeIndex = 0
    private var speechChunkOffset = 0
    private var activeUtteranceId: String? = null
    private var speechPaused = false
    private val holdToTalkSegments = mutableListOf<String>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var restartRunnable: Runnable? = null
    private var finalizeRunnable: Runnable? = null

    fun getAvailability(): Map<String, Any?> {
        val speechComponent = findGoogleRecognitionComponent()
        val ttsInstalled = isPackageInstalled(GOOGLE_TTS_PACKAGE)
        return mapOf(
            "speechAvailable" to (speechComponent != null),
            "speechEngine" to (speechComponent?.packageName ?: ""),
            "ttsAvailable" to ttsInstalled,
            "ttsEngine" to if (ttsInstalled) GOOGLE_TTS_PACKAGE else ""
        )
    }

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
                        installTtsProgressListener()
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
        val availability = getAvailability()
        return availability["speechAvailable"] == true ||
            availability["ttsAvailable"] == true
    }

    fun startListening(languageTag: String?, holdToTalk: Boolean = false): Boolean {
        if (recognizer == null) initialize()
        val speechRecognizer = recognizer ?: run {
            return false
        }

        activeLanguage = languageTag?.takeIf { it.isNotBlank() } ?: "es-AR"
        this.holdToTalk = holdToTalk
        stoppingHoldToTalk = false
        cancelHoldToTalkCallbacks()
        holdToTalkSegments.clear()
        currentPartial = ""
        listening = false
        return startRecognition(speechRecognizer)
    }

    private fun startRecognition(speechRecognizer: SpeechRecognizer): Boolean {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, activeLanguage)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, activeLanguage)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            if (holdToTalk) {
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                    12_000L
                )
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                    12_000L
                )
            }
        }

        return try {
            speechRecognizer.startListening(intent)
            listening = true
            emit(mapOf("type" to "listening", "language" to activeLanguage))
            true
        } catch (_: SecurityException) {
            listening = false
            false
        } catch (_: IllegalStateException) {
            listening = false
            false
        }
    }

    fun stopListening() {
        if (holdToTalk) {
            holdToTalk = false
            stoppingHoldToTalk = true
            cancelRestart()
            if (!listening) {
                finishHoldToTalk()
                return
            }
            try {
                recognizer?.stopListening()
                scheduleHoldToTalkFinalize()
            } catch (_: IllegalStateException) {
                recognizer?.cancel()
                finishHoldToTalk()
            }
            return
        }

        cancelHoldToTalkCallbacks()
        stoppingHoldToTalk = false
        listening = false
        try {
            recognizer?.stopListening()
        } catch (_: IllegalStateException) {
            recognizer?.cancel()
        }
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
        speechText = text
        speechResumeIndex = 0
        speechChunkOffset = 0
        speechPaused = false
        if (!speakFromOffset(tts, 0)) {
            clearSpeechState()
            emit(
                mapOf(
                    "type" to "error",
                    "code" to "tts_failed",
                    "message" to "Google Text-to-Speech could not start."
                )
            )
            return false
        }
        emit(mapOf("type" to "speaking"))
        return true
    }

    fun pauseSpeaking(): Boolean {
        if (speechText.isEmpty() || speechPaused || activeUtteranceId == null) {
            return false
        }
        speechPaused = true
        textToSpeech?.stop()
        emit(mapOf("type" to "speechPaused"))
        return true
    }

    fun resumeSpeaking(): Boolean {
        if (!speechPaused || speechText.isEmpty()) return false
        val tts = textToSpeech ?: return false
        speechPaused = false
        val offset = speechResumeIndex.coerceIn(0, speechText.length)
        if (offset >= speechText.length) {
            clearSpeechState()
            emit(mapOf("type" to "speechCompleted"))
            return true
        }
        if (!speakFromOffset(tts, offset)) {
            speechPaused = true
            emit(mapOf("type" to "speechPaused"))
            return false
        }
        emit(mapOf("type" to "speechResumed"))
        return true
    }

    fun stopSpeaking() {
        clearSpeechState()
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
        clearSpeechState()
        ttsReady = false
        listening = false
        holdToTalk = false
        stoppingHoldToTalk = false
        holdToTalkSegments.clear()
        currentPartial = ""
        cancelHoldToTalkCallbacks()
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
        if (!holdToTalk && !stoppingHoldToTalk) {
            listening = false
        }
        emit(mapOf("type" to "end"))
    }

    override fun onError(error: Int) {
        listening = false
        if (stoppingHoldToTalk) {
            appendHoldToTalkSegment(currentPartial)
            finishHoldToTalk()
            return
        }
        if (holdToTalk && isRetryableHoldToTalkError(error)) {
            appendHoldToTalkSegment(currentPartial)
            currentPartial = ""
            emit(mapOf("type" to "partial", "text" to buildHoldToTalkTranscript()))
            scheduleHoldToTalkRestart()
            return
        }
        holdToTalk = false
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
        if (holdToTalk || stoppingHoldToTalk) {
            appendHoldToTalkSegment(text.ifBlank { currentPartial })
            currentPartial = ""
            if (stoppingHoldToTalk) {
                finishHoldToTalk()
            } else {
                emit(mapOf("type" to "partial", "text" to buildHoldToTalkTranscript()))
                scheduleHoldToTalkRestart()
            }
        } else {
            emit(mapOf("type" to "final", "text" to text))
        }
    }

    override fun onPartialResults(partialResults: Bundle?) {
        val text = partialResults
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            .orEmpty()
        if (text.isNotBlank()) {
            if (holdToTalk || stoppingHoldToTalk) {
                currentPartial = text
                emit(
                    mapOf(
                        "type" to "partial",
                        "text" to buildHoldToTalkTranscript(includeCurrentPartial = true)
                    )
                )
            } else {
                emit(mapOf("type" to "partial", "text" to text))
            }
        }
    }

    override fun onEvent(eventType: Int, params: Bundle?) = Unit

    private fun appendHoldToTalkSegment(text: String) {
        val segment = text.trim()
        if (segment.isNotEmpty() &&
            (holdToTalkSegments.isEmpty() || holdToTalkSegments.last() != segment)
        ) {
            holdToTalkSegments.add(segment)
        }
    }

    private fun buildHoldToTalkTranscript(
        includeCurrentPartial: Boolean = false
    ): String {
        val parts = holdToTalkSegments.toMutableList()
        if (includeCurrentPartial && currentPartial.isNotBlank()) {
            parts.add(currentPartial.trim())
        }
        return parts.joinToString(" ")
    }

    private fun scheduleHoldToTalkRestart() {
        cancelRestart()
        val restart = Runnable {
            restartRunnable = null
            if (!holdToTalk || stoppingHoldToTalk) return@Runnable
            val speechRecognizer = recognizer ?: return@Runnable
            if (!startRecognition(speechRecognizer)) {
                holdToTalk = false
                emit(
                    mapOf(
                        "type" to "error",
                        "code" to "recognition_restart_failed",
                        "message" to "Speech recognition could not resume."
                    )
                )
            }
        }
        restartRunnable = restart
        mainHandler.postDelayed(restart, 250L)
    }

    private fun scheduleHoldToTalkFinalize() {
        finalizeRunnable?.let { mainHandler.removeCallbacks(it) }
        val finalize = Runnable {
            finalizeRunnable = null
            if (stoppingHoldToTalk) finishHoldToTalk()
        }
        finalizeRunnable = finalize
        mainHandler.postDelayed(finalize, 1_800L)
    }

    private fun finishHoldToTalk() {
        cancelHoldToTalkCallbacks()
        appendHoldToTalkSegment(currentPartial)
        currentPartial = ""
        val transcript = buildHoldToTalkTranscript()
        listening = false
        holdToTalk = false
        stoppingHoldToTalk = false
        emit(mapOf("type" to "final", "text" to transcript))
        holdToTalkSegments.clear()
    }

    private fun cancelRestart() {
        restartRunnable?.let { mainHandler.removeCallbacks(it) }
        restartRunnable = null
    }

    private fun cancelHoldToTalkCallbacks() {
        cancelRestart()
        finalizeRunnable?.let { mainHandler.removeCallbacks(it) }
        finalizeRunnable = null
    }

    private fun isRetryableHoldToTalkError(error: Int): Boolean {
        return error == SpeechRecognizer.ERROR_NO_MATCH ||
            error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT ||
            error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY
    }

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

    private fun installTtsProgressListener() {
        textToSpeech?.setOnUtteranceProgressListener(
            object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit

                override fun onDone(utteranceId: String?) {
                    if (utteranceId != activeUtteranceId || speechPaused) return
                    clearSpeechState()
                    emit(mapOf("type" to "speechCompleted"))
                }

                override fun onError(utteranceId: String?) {
                    if (utteranceId != activeUtteranceId) return
                    clearSpeechState()
                    emit(mapOf("type" to "speechFailed"))
                }

                override fun onStop(utteranceId: String?, interrupted: Boolean) {
                    if (utteranceId != activeUtteranceId || speechPaused) return
                    clearSpeechState()
                    emit(mapOf("type" to "speechStopped"))
                }

                override fun onRangeStart(
                    utteranceId: String?,
                    start: Int,
                    end: Int,
                    frame: Int
                ) {
                    if (utteranceId != activeUtteranceId) return
                    speechResumeIndex = (speechChunkOffset + start)
                        .coerceIn(0, speechText.length)
                }
            }
        )
    }

    private fun speakFromOffset(tts: TextToSpeech, offset: Int): Boolean {
        val remaining = speechText.substring(offset)
        val utteranceId = "privateagent-${System.nanoTime()}"
        speechChunkOffset = offset
        activeUtteranceId = utteranceId
        val result = tts.speak(
            remaining,
            TextToSpeech.QUEUE_FLUSH,
            Bundle(),
            utteranceId
        )
        return result != TextToSpeech.ERROR
    }

    private fun clearSpeechState() {
        speechText = ""
        speechResumeIndex = 0
        speechChunkOffset = 0
        activeUtteranceId = null
        speechPaused = false
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