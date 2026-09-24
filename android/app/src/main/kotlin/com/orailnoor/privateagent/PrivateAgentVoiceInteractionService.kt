package com.orailnoor.privateagent

import android.content.Intent
import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.util.Log

/**
 * Entry point Android uses when PrivateAgent is selected as the default assistant.
 *
 * The service does not perform task actions itself. It opens the normal Agent UI,
 * which uses the shared task executor and outcome verification.
 */
class PrivateAgentVoiceInteractionService : VoiceInteractionService() {
    override fun onReady() {
        super.onReady()
    }

    override fun onShutdown() {
        super.onShutdown()
    }
}

class PrivateAgentVoiceInteractionSessionService : android.service.voice.VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): android.service.voice.VoiceInteractionSession {
        return PrivateAgentVoiceInteractionSession(this)
    }
}

private class PrivateAgentVoiceInteractionSession(
    service: android.content.Context
) : android.service.voice.VoiceInteractionSession(service) {
    private val hostContext = service

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        val intent = Intent(hostContext, MainActivity::class.java)
            .setAction(Intent.ACTION_ASSIST)
            .putExtra(MainActivity.EXTRA_ASSISTANT_INVOCATION, true)
            .putExtra(MainActivity.EXTRA_FORCE_AGENT_MODE, true)
            .addFlags(
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            )
        try {
            startVoiceActivity(intent)
        } catch (error: RuntimeException) {
            Log.e("PrivateAgent", "Voice activity launch failed; opening the app.", error)
            try {
                hostContext.startActivity(
                    Intent(hostContext, MainActivity::class.java)
                        .setAction(Intent.ACTION_ASSIST)
                        .putExtra(MainActivity.EXTRA_ASSISTANT_INVOCATION, true)
                        .putExtra(MainActivity.EXTRA_FORCE_AGENT_MODE, true)
                        .addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP
                        )
                    )
            } catch (fallbackError: RuntimeException) {
                Log.e("PrivateAgent", "Fallback assistant launch failed.", fallbackError)
            }
        }
    }
}