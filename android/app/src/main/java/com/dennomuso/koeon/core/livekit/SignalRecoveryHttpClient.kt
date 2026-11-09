package com.dennomuso.koeon.core.livekit

import okhttp3.Call
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/**
 * LiveKit Android 2.28.0 waits for onClosed to resume, but its onClosing does not
 * acknowledge a peer's close frame. Complete the handshake so recovery does not
 * wait for the server's socket timeout and outlive participant retention.
 * Remove this adapter when the pinned SDK acknowledges peer-initiated closure.
 */
internal class SignalRecoveryHttpClient : OkHttpClient() {
    // This is a diagnostic request after signaling failure, not the connection or
    // membership handshake. Do not let it postpone SDK recovery for 10+ seconds.
    private val validationClient by lazy {
        newBuilder().callTimeout(1, TimeUnit.SECONDS).retryOnConnectionFailure(false).build()
    }

    override fun newCall(request: Request): Call =
        if (request.url.encodedPath == "/rtc/validate") validationClient.newCall(request)
        else super.newCall(request)

    override fun newWebSocket(request: Request, listener: WebSocketListener): WebSocket =
        super.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = listener.onOpen(webSocket, response)
            override fun onMessage(webSocket: WebSocket, text: String) = listener.onMessage(webSocket, text)
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) = listener.onMessage(webSocket, bytes)
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                try {
                    listener.onClosing(webSocket, code, reason)
                } finally {
                    // 1005 denotes an empty close frame and cannot be sent on the wire.
                    webSocket.close(if (code == 1005) 1000 else code, null)
                }
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) =
                listener.onClosed(webSocket, code, reason)
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                listener.onFailure(webSocket, t, response)
        })
}

// Match the SDK lifetime: reuse the pool and dispatcher across Room recreation.
internal val liveKitSignalHttpClient by lazy { SignalRecoveryHttpClient() }
