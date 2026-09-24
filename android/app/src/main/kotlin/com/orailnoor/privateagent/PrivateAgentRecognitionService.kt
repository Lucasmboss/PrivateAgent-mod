package com.orailnoor.privateagent

import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognitionService.Callback
import android.speech.SpeechRecognizer

/**
 * Provides the recognition-service component required by Android's assistant
 * role. Speech is delegated to the device's configured recognizer.
 */
class PrivateAgentRecognitionService : RecognitionService() {
    private var generation = 0L
    private var activeGeneration = 0L
    private var activeRecognizer: SpeechRecognizer? = null
    private var activeCallback: Callback? = null

    override fun onStartListening(intent: Intent, listener: Callback) {
        cancelActiveSession()
        val session = ++generation

        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            listener.error(SpeechRecognizer.ERROR_CLIENT)
            return
        }

        val recognizer = try {
            SpeechRecognizer.createSpeechRecognizer(applicationContext)
        } catch (_: RuntimeException) {
            listener.error(SpeechRecognizer.ERROR_CLIENT)
            return
        }

        activeGeneration = session
        activeRecognizer = recognizer
        activeCallback = listener
        recognizer.setRecognitionListener(
            object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    withActiveCallback(session) {
                        it.readyForSpeech(params ?: Bundle())
                    }
                }

                override fun onBeginningOfSpeech() {
                    withActiveCallback(session) { it.beginningOfSpeech() }
                }

                override fun onRmsChanged(rmsdB: Float) {
                    withActiveCallback(session) { it.rmsChanged(rmsdB) }
                }

                override fun onBufferReceived(buffer: ByteArray?) {
                    if (buffer != null) {
                        withActiveCallback(session) { it.bufferReceived(buffer) }
                    }
                }

                override fun onEndOfSpeech() {
                    // The final result may arrive after this callback.
                    withActiveCallback(session) { it.endOfSpeech() }
                }

                override fun onError(error: Int) {
                    withActiveCallback(session) { it.error(error) }
                    finishSession(session)
                }

                override fun onResults(results: Bundle?) {
                    withActiveCallback(session) { it.results(results ?: Bundle()) }
                    finishSession(session)
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    withActiveCallback(session) {
                        it.partialResults(partialResults ?: Bundle())
                    }
                }

                override fun onEvent(eventType: Int, params: Bundle?) = Unit
            },
        )

        try {
            recognizer.startListening(intent)
        } catch (_: RuntimeException) {
            listener.error(SpeechRecognizer.ERROR_CLIENT)
            finishSession(session)
        }
    }

    override fun onStopListening(listener: Callback) {
        if (activeCallback !== listener || activeRecognizer == null) {
            listener.error(SpeechRecognizer.ERROR_CLIENT)
            return
        }
        try {
            activeRecognizer?.stopListening()
        } catch (_: RuntimeException) {
            listener.error(SpeechRecognizer.ERROR_CLIENT)
            cancelActiveSession()
        }
    }

    override fun onCancel(listener: Callback) {
        if (activeCallback === listener) cancelActiveSession()
    }

    override fun onDestroy() {
        cancelActiveSession()
        super.onDestroy()
    }

    private inline fun withActiveCallback(
        session: Long,
        action: (Callback) -> Unit,
    ) {
        if (session == activeGeneration) activeCallback?.let(action)
    }

    private fun finishSession(session: Long) {
        if (session != activeGeneration) return
        val recognizer = activeRecognizer
        activeGeneration = 0
        activeRecognizer = null
        activeCallback = null
        recognizer?.destroy()
    }

    private fun cancelActiveSession() {
        val recognizer = activeRecognizer
        activeGeneration = 0
        activeRecognizer = null
        activeCallback = null
        if (recognizer != null) {
            try {
                recognizer.cancel()
            } catch (_: RuntimeException) {
                // The recognizer may already have ended.
            }
            recognizer.destroy()
        }
    }
}